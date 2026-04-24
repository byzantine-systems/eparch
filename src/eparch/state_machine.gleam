//// A type-safe, OTP-compatible, finite state machine implementation that
//// leverages Erlang's [gen_statem](https://www.erlang.org/doc/apps/stdlib/gen_statem.html) behavior throught the [Gleam ffi](https://gleam.run/documentation/externals/#Erlang-externals).
////
//// ## Differences from `gen_statem`
////
//// Unlike Erlang's `gen_statem`, this implementation:
//// - Uses a single `Event` type to unify calls, casts, and info messages
//// - Makes actions explicit and type-safe (no raw tuples)
//// - Makes [state_enter](https://www.erlang.org/doc/apps/stdlib/gen_statem.html#t:state_enter/0) an opt-in feature, you need to explicity set it so in the Builder.
//// - Returns strongly-typed Steps instead of various tuple formats
////

import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type ExitReason, type Pid, type Subject}
import gleam/option.{type Option, None, Some}

type StateEnter {
  StateEnterEnabled
  StateEnterDisabled
}

/// A builder for configuring a state machine before starting it.
///
/// Generic parameters:
/// - `state`: The type of state values (e.g., enum, custom type)
/// - `data`: The type of data carried across state transitions
/// - `msg`: The type of messages the state machine receives
/// - `return`: What the start function returns to the parent
///
pub opaque type Builder(state, data, msg, return, reply) {
  Builder(
    initial_state: state,
    initial_data: data,
    event_handler: fn(Event(state, msg, reply), state, data) ->
      Step(state, data, msg, reply),
    state_enter: StateEnter,
    initialisation_timeout: Int,
    name: Option(process.Name(msg)),
    on_code_change: Option(fn(data) -> data),
  )
}

/// Events that a state machine can receive.
///
/// This unifies the three types of messages in OTP:
/// - Calls (synchronous, requires reply)
/// - Casts (asynchronous / fire-and-forget)
/// - Info (other messages, from selectors/monitors)
///
pub type Event(state, msg, reply) {
  /// A synchronous call that expects a reply
  Call(from: From(reply), message: msg)

  /// An asynchronous cast (fire-and-forget)
  Cast(message: msg)

  /// An info message (from selectors, monitors, etc)
  Info(message: msg)

  /// Internal event fired when entering a state (if state_enter enabled)
  /// Contains the previous state
  Enter(old_state: state)

  /// Timeout events (state timeout or generic timeout)
  Timeout(timeout: TimeoutType)
}

/// The result of handling an event.
///
/// Indicates what the state machine should do next.
///
pub type Step(state, data, msg, reply) {
  /// Transition to a new state
  NextState(state: state, data: data, actions: List(Action(msg, reply)))

  /// Keep the current state
  KeepState(data: data, actions: List(Action(msg, reply)))

  /// Stop the state machine
  Stop(reason: ExitReason)
}

/// Actions (side effects) to perform after handling an event.
///
/// Multiple actions can be returned as a list.
///
pub type Action(msg, reply) {
  /// Send a reply to a caller
  Reply(from: From(reply), response: reply)

  /// Postpone this event until after a state change
  Postpone

  /// Insert a new event at the front of the queue
  NextEvent(content: msg)

  /// Set a state timeout (canceled on state change)
  StateTimeout(milliseconds: Int)

  /// Set a generic named timeout
  GenericTimeout(name: String, milliseconds: Int)

  /// Change the gen_statem callback module to `module`.
  /// The new module receives the internal `#gleam_statem` record as its data,
  /// use only for Erlang interop with modules that understand eparch's internals.
  ChangeCallbackModule(module: Atom)

  /// Push the current callback module onto an internal stack and switch to `module`.
  /// Pop with `PopCallbackModule` to restore. Otherwise like `ChangeCallbackModule`.
  PushCallbackModule(module: Atom)

  /// Pop the top module from the internal callback-module stack and switch to it.
  /// Fails the server if the stack is empty.
  PopCallbackModule
}

/// Types of timeouts
pub type TimeoutType {
  StateTimeoutType
  GenericTimeoutType(name: String)
}

/// Opaque reference to a caller (for replying to calls).
///
/// Represents Erlang's `gen_statem:from()` type. Values of this type
/// only ever originate from a `Call` event delivered by the gen_statem
/// runtime.
///
pub type From(reply)

/// Data returned when a state machine starts successfully.
pub type Started(data) {
  Started(
    /// The process identifier of the started state machine
    pid: Pid,
    /// Data returned after initialization (typically a Subject)
    data: data,
  )
}

/// Errors that can occur when starting a state machine.
pub type StartError {
  InitTimeout
  InitFailed(String)
  InitExited(ExitReason)
}

/// Convenience type for start results.
pub type StartResult(data) =
  Result(Started(data), StartError)

/// An opaque request ID returned by `send_request`.
///
/// The phantom type `reply` tracks the expected response type at compile time.
/// Requires Erlang/OTP 25.0 or later.
///
pub type ReqId(reply)

/// A collection of in-flight request IDs, each associated with a `label`.
///
/// Used with `send_request_to_collection`, `reqids_add`, and
/// `receive_response_collection` to manage multiple concurrent requests.
/// Requires Erlang/OTP 25.0 or later.
///
pub type ReqIdCollection(label, reply)

/// The result of waiting for a response from a `ReqIdCollection`.
///
pub type CollectionResponse(reply, label) {
  /// A successful reply was received for one of the pending requests.
  GotReply(reply: reply, label: label, remaining: ReqIdCollection(label, reply))

  /// One of the requests returned an error (e.g. the server crashed).
  RequestFailed(
    reason: Dynamic,
    label: label,
    remaining: ReqIdCollection(label, reply),
  )

  /// The collection had no pending requests.
  NoRequests
}

/// Create a new state machine builder with initial state and data.
///
/// By default, the state machine will return a Subject that can be used
/// to send messages to it.
///
/// ## Example
///
/// ```gleam
/// state_machine.new(initial_state: Idle, initial_data: 0)
/// |> state_machine.on_event(handle_event)
/// |> state_machine.start
/// ```
///
pub fn new(
  initial_state initial_state: state,
  initial_data initial_data: data,
) -> Builder(state, data, msg, Subject(msg), reply) {
  Builder(
    initial_state: initial_state,
    initial_data: initial_data,
    event_handler: fn(_, _state, data) { keep_state(data, []) },
    state_enter: StateEnterDisabled,
    initialisation_timeout: 1000,
    name: None,
    on_code_change: None,
  )
}

/// Set the event handler callback function.
///
/// This function is called for every event the state machine receives.
/// It takes the current event, state, and data, and returns a Step
/// indicating what to do next.
///
/// ## Example
///
/// ```gleam
/// fn handle_event(event, state, data) {
///   case event, state {
///     Call(from, GetCount), Running ->
///       keep_state(data, [Reply(from, data.count)])
///
///     Cast(Increment), Running ->
///       keep_state(Data(..data, count: data.count + 1), [])
///
///     _, _ -> keep_state(data, [])
///   }
/// }
///
/// state_machine.new(Running, Data(0))
/// |> state_machine.on_event(handle_event)
/// |> state_machine.start
/// ```
///
pub fn on_event(
  builder: Builder(state, data, msg, return, reply),
  handler: fn(Event(state, msg, reply), state, data) ->
    Step(state, data, msg, reply),
) -> Builder(state, data, msg, return, reply) {
  Builder(..builder, event_handler: handler)
}

/// Enable [state_enter](https://www.erlang.org/doc/apps/stdlib/gen_statem.html#t:state_enter/0) calls.
///
/// When enabled, your event handler will be called with an `Enter` event
/// whenever the state changes. This allows you to perform actions when
/// entering a state (like setting timeouts, logging, etc).
///
/// The Enter event contains the previous state.
///
/// ## Example
///
/// ```gleam
/// fn handle_event(event, state, data) {
///   case event, state {
///     Enter(old), Active if old != Active -> {
///       // Perform entry actions
///       keep_state(data, [StateTimeout(30_000)])
///     }
///     _, _ -> keep_state(data, [])
///   }
/// }
///
/// state_machine.new(Idle, data)
/// |> state_machine.with_state_enter()
/// |> state_machine.on_event(handle_event)
/// |> state_machine.start
/// ```
///
pub fn with_state_enter(
  builder: Builder(state, data, msg, return, reply),
) -> Builder(state, data, msg, return, reply) {
  Builder(..builder, state_enter: StateEnterEnabled)
}

/// Provide a name for the state machine to be registered with when started.
///
/// This enables sending messages to it via a named subject.
///
pub fn named(
  builder: Builder(state, data, msg, return, reply),
  name: process.Name(msg),
) -> Builder(state, data, msg, return, reply) {
  Builder(..builder, name: Some(name))
}

/// Provide a migration function called during hot-code upgrades.
///
/// When an OTP release upgrades the running code, `gen_statem` calls
/// `code_change/4`. If a migration function is set, it receives the current
/// data value and its return value becomes the new data. Use this to migrate
/// data structures between versions without restarting the process.
///
/// If not set, the data passes through unchanged (the default and safe
/// behaviour for most applications).
///
/// ## Example
///
/// ```gleam
/// // Old data shape: Int
/// // New data shape: Data(count: Int, label: String)
/// state_machine.new(Idle, 0)
/// |> state_machine.on_code_change(fn(old_count) { Data(old_count, "default") })
/// |> state_machine.on_event(handle_event)
/// |> state_machine.start
/// ```
///
pub fn on_code_change(
  builder: Builder(state, data, msg, return, reply),
  handler: fn(data) -> data,
) -> Builder(state, data, msg, return, reply) {
  Builder(..builder, on_code_change: Some(handler))
}

/// Start the state machine process.
///
/// Spawns a linked gen_statem process, runs initialisation, and returns
/// a `Started` value containing the PID and a `Subject` that can be used
/// to send messages to the machine.
///
/// ## Example
///
/// ```gleam
/// let assert Ok(machine) =
///   state_machine.new(initial_state: Idle, initial_data: 0)
///   |> state_machine.on_event(handle_event)
///   |> state_machine.start
///
/// // Send a fire-and-forget message
/// process.send(machine.data, SomeMessage)
///
/// // Send a synchronous message with a reply
/// let reply = process.call(machine.data, 1000, SomeRequest)
/// ```
///
pub fn start(
  builder: Builder(state, data, msg, Subject(msg), reply),
) -> Result(Started(Subject(msg)), StartError) {
  let Builder(
    initial_state:,
    initial_data:,
    event_handler:,
    state_enter:,
    initialisation_timeout:,
    name:,
    on_code_change:,
  ) = builder
  do_start(
    initial_state,
    initial_data,
    event_handler,
    state_enter,
    initialisation_timeout,
    name,
    on_code_change,
  )
}

@external(erlang, "statem_ffi", "do_start")
fn do_start(
  initial_state: state,
  initial_data: data,
  event_handler: fn(Event(state, msg, reply), state, data) ->
    Step(state, data, msg, reply),
  state_enter: StateEnter,
  initialisation_timeout: Int,
  name: Option(process.Name(msg)),
  on_code_change: Option(fn(data) -> data),
) -> Result(Started(Subject(msg)), StartError)

/// Create a NextState step indicating a state transition.
///
/// ## Example
///
/// ```gleam
/// next_state(Active, new_data, [StateTimeout(5000)])
/// ```
///
pub fn next_state(
  state: state,
  data: data,
  actions: List(Action(msg, reply)),
) -> Step(state, data, msg, reply) {
  NextState(state:, data:, actions:)
}

/// Create a KeepState step indicating no state change.
///
/// ## Example
///
/// ```gleam
/// keep_state(data, [])
/// ```
///
pub fn keep_state(
  data: data,
  actions: List(Action(msg, reply)),
) -> Step(state, data, msg, reply) {
  KeepState(data:, actions:)
}

/// Create a Stop step indicating the state machine should terminate.
///
/// ## Example
///
/// ```gleam
/// stop(process.Normal)
/// ```
///
pub fn stop(reason: ExitReason) -> Step(state, data, msg, reply) {
  Stop(reason:)
}

/// Create a Reply action.
///
/// ## Example
///
/// ```gleam
/// case event {
///   Call(from, GetData) -> keep_state(data, [Reply(from, data)])
///   _ -> keep_state(data, [])
/// }
/// ```
///
pub fn reply(from: From(reply), response: reply) -> Action(msg, reply) {
  Reply(from:, response:)
}

/// Create a Postpone action.
///
/// Postpones the current event until after the next state change.
///
pub fn postpone() -> Action(msg, reply) {
  Postpone
}

/// Create a NextEvent action.
///
/// Inserts a new event at the front of the event queue.
///
pub fn next_event(content: msg) -> Action(msg, reply) {
  NextEvent(content:)
}

/// Create a StateTimeout action.
///
/// Sets a timeout that is automatically canceled when the state changes.
///
pub fn state_timeout(milliseconds: Int) -> Action(msg, reply) {
  StateTimeout(milliseconds:)
}

/// Create a GenericTimeout action.
///
/// Sets a named timeout that persists across state changes.
///
pub fn generic_timeout(name: String, milliseconds: Int) -> Action(msg, reply) {
  GenericTimeout(name:, milliseconds:)
}

/// Create a ChangeCallbackModule action.
///
/// Swaps the gen_statem callback module at runtime. The new module receives
/// the internal `#gleam_statem` record as its data, so it must be an Erlang
/// module written to understand eparch internals. Use only for advanced
/// Erlang interop; most applications should not need this.
///
/// Since OTP 22.3.
///
/// ## Example
///
/// ```gleam
/// state_machine.change_callback_module(atom.create("my_erlang_module"))
/// ```
///
pub fn change_callback_module(module: Atom) -> Action(msg, reply) {
  ChangeCallbackModule(module:)
}

/// Create a PushCallbackModule action.
///
/// Pushes the current callback module onto an internal stack and switches
/// to `module`. Restore the previous module with `pop_callback_module`.
/// Same data-sharing caveats as `change_callback_module` apply.
///
/// Since OTP 22.3.
///
/// ## Example
///
/// ```gleam
/// state_machine.push_callback_module(atom.create("my_erlang_module"))
/// ```
///
pub fn push_callback_module(module: Atom) -> Action(msg, reply) {
  PushCallbackModule(module:)
}

/// Create a PopCallbackModule action.
///
/// Pops the top module off the callback-module stack and switches to it.
/// Fails the server if the stack is empty, so only use after a matching
/// `push_callback_module`.
///
/// Since OTP 22.3.
///
/// ## Example
///
/// ```gleam
/// state_machine.pop_callback_module()
/// ```
///
pub fn pop_callback_module() -> Action(msg, reply) {
  PopCallbackModule
}

/// Reply and transition to a new state.
///
/// ## Example
///
/// ```gleam
/// reply_and_next(from, Ok(Nil), Active, new_data)
/// ```
///
pub fn reply_and_next(
  from: From(reply),
  response: reply,
  state: state,
  data: data,
) -> Step(state, data, msg, reply) {
  NextState(state:, data:, actions: [Reply(from:, response:)])
}

/// Reply and keep the current state.
///
/// ## Example
///
/// ```gleam
/// reply_and_keep(from, Ok(data.count), data)
/// ```
///
pub fn reply_and_keep(
  from: From(reply),
  response: reply,
  data: data,
) -> Step(state, data, msg, reply) {
  KeepState(data:, actions: [Reply(from:, response:)])
}

/// Send a message to a state machine via `process.send` (arrives as `Info`).
///
/// The message is delivered to the handler as `Info(msg)`. Use this for
/// messages sent from processes that are not aware of this library, e.g.
/// monitors, timers, or plain Erlang processes.
///
/// To deliver messages as `Cast(msg)` instead, use `cast/2`.
///
pub fn send(subject: Subject(msg), msg: msg) -> Nil {
  process.send(subject, msg)
}

/// Send an asynchronous cast to a state machine (arrives as `Cast`).
///
/// Unlike `send`, which routes messages through `process.send` and delivers
/// them as `Info(msg)`, this function calls `gen_statem:cast` so messages
/// arrive as `Cast(msg)` in the event handler.
///
/// Use `cast` when you want to distinguish machine-level commands from
/// ambient info messages (monitors, raw Erlang signals, etc.).
///
/// ## Example
///
/// ```gleam
/// fn handle_event(event, state, data) {
///   case event {
///     Cast(Increment) -> keep_state(data + 1, [])
///     Info(_)         -> keep_state(data, [])   // ignore ambient noise
///     _               -> keep_state(data, [])
///   }
/// }
/// ```
///
@external(erlang, "statem_ffi", "cast")
pub fn cast(subject: Subject(msg), msg: msg) -> Nil

/// Send a synchronous call and wait for a reply.
///
/// This is a re-export of `process.call` for convenience.
///
pub fn call(
  subject: Subject(message),
  waiting timeout: Int,
  sending make_message: fn(Subject(reply)) -> message,
) -> reply {
  process.call(subject, timeout, make_message)
}

// ── reqids API (OTP 25.0+) ─────────────────────────────────────────────────

/// Create a new, empty request-id collection.
///
/// Used with `send_request_to_collection` to batch multiple async requests and
/// then receive them through `receive_response_collection`.
///
/// Requires Erlang/OTP 25.0 or later.
///
@external(erlang, "statem_ffi", "reqids_new")
pub fn reqids_new() -> ReqIdCollection(label, reply)

/// Add a `ReqId` to a collection under a `label`.
///
/// The label is returned alongside the reply in `receive_response_collection`,
/// letting you identify which request the response belongs to.
///
/// Requires Erlang/OTP 25.0 or later.
///
@external(erlang, "statem_ffi", "reqids_add")
pub fn reqids_add(
  req_id req_id: ReqId(reply),
  label label: label,
  to collection: ReqIdCollection(label, reply),
) -> ReqIdCollection(label, reply)

/// Return the number of pending request IDs in a collection.
///
/// Requires Erlang/OTP 25.0 or later.
///
@external(erlang, "statem_ffi", "reqids_size")
pub fn reqids_size(collection: ReqIdCollection(label, reply)) -> Int

/// Convert a collection to a list of `#(ReqId, label)` pairs.
///
/// Requires Erlang/OTP 25.0 or later.
///
@external(erlang, "statem_ffi", "reqids_to_list")
pub fn reqids_to_list(
  collection: ReqIdCollection(label, reply),
) -> List(#(ReqId(reply), label))

/// Send an asynchronous call to a state machine and return a `ReqId`.
///
/// Unlike `call`, this does not block. Use `receive_response` later to
/// collect the reply. The server receives a `Call(from, message)` event
/// and must reply with a `Reply(from, value)` action.
///
/// The `reply` type cannot always be inferred — annotate the binding when
/// needed: `let req: ReqId(MyReply) = send_request(subject, MyMsg)`
///
/// ## Example
///
/// ```gleam
/// let req: state_machine.ReqId(Int) = state_machine.send_request(machine.data, GetCount)
/// // ... do other work ...
/// let assert Ok(count) = state_machine.receive_response(req, 1000)
/// ```
///
/// Requires Erlang/OTP 25.0 or later.
///
@external(erlang, "statem_ffi", "send_request")
pub fn send_request(subject: Subject(msg), message: msg) -> ReqId(reply)

/// Send an asynchronous call and immediately add the `ReqId` to a collection.
///
/// Equivalent to calling `send_request` and `reqids_add` in one step. Useful
/// for issuing several requests in a loop before waiting for any of them.
///
/// ## Example
///
/// ```gleam
/// let coll: state_machine.ReqIdCollection(String, Int) = state_machine.reqids_new()
/// let coll = state_machine.send_request_to_collection(sub, GetCount, "first", coll)
/// let coll = state_machine.send_request_to_collection(sub, GetCount, "second", coll)
/// // ... receive responses via receive_response_collection ...
/// ```
///
/// Requires Erlang/OTP 25.0 or later.
///
@external(erlang, "statem_ffi", "send_request_to_collection")
pub fn send_request_to_collection(
  subject: Subject(msg),
  message: msg,
  label: label,
  to collection: ReqIdCollection(label, reply),
) -> ReqIdCollection(label, reply)

/// Wait up to `timeout` milliseconds for the reply to a single `ReqId`.
///
/// Returns `Ok(reply)` on success or `Error(reason)` on failure or timeout.
///
/// Requires Erlang/OTP 25.0 or later.
///
@external(erlang, "statem_ffi", "receive_response")
pub fn receive_response(
  req_id: ReqId(reply),
  timeout: Int,
) -> Result(reply, Dynamic)

/// Wait up to `timeout` milliseconds for any pending reply in a collection.
///
/// When `delete` is `True`, the matched request is removed from the returned
/// collection. Call this in a loop to drain all responses one by one.
///
/// ## Example
///
/// ```gleam
/// let assert state_machine.GotReply(val, label, coll) =
///   state_machine.receive_response_collection(coll, 1000, True)
/// ```
///
/// Requires Erlang/OTP 25.0 or later.
///
@external(erlang, "statem_ffi", "receive_response_collection")
pub fn receive_response_collection(
  collection: ReqIdCollection(label, reply),
  timeout: Int,
  delete: Bool,
) -> CollectionResponse(reply, label)
