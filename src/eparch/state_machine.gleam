//// A type-safe, OTP-compatible, finite state machine implementation that
//// leverages Erlang's [gen_statem](https://www.erlang.org/doc/apps/stdlib/gen_statem.html) behavior through the [Gleam ffi](https://gleam.run/documentation/externals/#Erlang-externals).
////
//// ## Differences from `gen_statem`
////
//// Unlike Erlang's `gen_statem`, this implementation:
//// - Uses a single `Event` type to unify calls, casts, and info messages
//// - Makes actions explicit and type-safe (no raw tuples)
//// - Makes [state_enter](https://www.erlang.org/doc/apps/stdlib/gen_statem.html#t:state_enter/0) an opt-in feature, you need to explicitly set it so in the Builder.
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
/// - `message`: The type of messages the state machine receives
/// - `return`: What the start function returns to the parent
/// - `reply`: The type of replies produced for synchronous `Call` events
///
pub opaque type Builder(state, data, message, return, reply) {
  Builder(
    initial_state: state,
    initial_data: data,
    event_handler: fn(Event(state, message, reply), state, data) ->
      Step(state, data, message, reply),
    state_enter: StateEnter,
    initialisation_timeout: Int,
    name: Option(process.Name(message)),
    on_code_change: Option(fn(data) -> data),
    on_format_status: Option(
      fn(Status(state, data, message, reply)) ->
        Status(state, data, message, reply),
    ),
  )
}

/// Snapshot of the state machine passed to the `format_status` callback.
///
/// Mirrors the OTP 25+ `format_status/1` map for `gen_statem`. The `state`
/// and `data` fields always carry the current typed values. The remaining
/// fields correspond to OTP map keys that are only present in certain
/// contexts (e.g. `reason` during termination, `queue` during sys calls).
/// Return a modified `Status` from your formatter to control what
/// `sys:get_status/1` and SASL crash reports display.
///
/// `log` stays as `List(Dynamic)` because `sys:system_event()` is an
/// internal Erlang shape with no stable Gleam equivalent.
///
pub type Status(state, data, message, reply) {
  Status(
    state: state,
    data: data,
    reason: Option(StopReason),
    queue: List(QueuedEvent(message, reply)),
    postponed: List(QueuedEvent(message, reply)),
    timeouts: List(ActiveTimeout(message)),
    log: List(Dynamic),
  )
}

/// Termination reason as seen by `format_status/1`.
///
/// `Exit` wraps a recognised `process.ExitReason`. `RawReason` is a fallback
/// for reasons the FFI cannot classify (e.g. `{shutdown, _}`, `{noproc, _}`,
/// arbitrary user terms) so callers can still inspect or replace them.
///
pub type StopReason {
  Exit(reason: ExitReason)
  RawReason(term: Dynamic)
}

/// A pending event on the gen_statem queue or in the postponed list.
///
/// Mirrors the `Event` type but without the `Enter` variant (state-entry
/// events never queue). `QueuedOther` is a fallback for shapes the FFI does
/// not recognise, so the formatter never crashes on an unexpected OTP event
/// type.
///
pub type QueuedEvent(message, reply) {
  QueuedCall(from: From(reply), message: message)
  QueuedCast(message: message)
  QueuedInfo(message: message)
  QueuedInternal(message: message)
  QueuedStateTimeout(content: message)
  QueuedGenericTimeout(name: String, content: message)
  QueuedOther(raw: Dynamic)
}

/// An armed (not-yet-fired) timeout on the state machine.
///
/// `ActiveOtherTimeout` handles any shape the FFI cannot classify as a
/// state or generic timeout.
///
pub type ActiveTimeout(message) {
  ActiveStateTimeout(content: message)
  ActiveGenericTimeout(name: String, content: message)
  ActiveOtherTimeout(raw: Dynamic)
}

/// Events that a state machine can receive.
///
/// This unifies the three types of messages in OTP:
/// - Calls (synchronous, requires reply)
/// - Casts (asynchronous / fire-and-forget)
/// - Info (other messages, from selectors/monitors)
///
pub type Event(state, message, reply) {
  /// A synchronous call that expects a reply
  Call(from: From(reply), message: message)

  /// An asynchronous cast (fire-and-forget)
  Cast(message: message)

  /// An info message (from selectors, monitors, etc)
  Info(message: message)

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
pub type Step(state, data, message, reply) {
  /// Transition to a new state
  NextState(state: state, data: data, actions: List(Action(message, reply)))

  /// Keep the current state
  KeepState(data: data, actions: List(Action(message, reply)))

  /// Stop the state machine
  Stop(reason: ExitReason)
}

/// Actions (side effects) to perform after handling an event.
///
/// Multiple actions can be returned as a list.
///
pub type Action(message, reply) {
  /// Send a reply to a caller
  Reply(from: From(reply), response: reply)

  /// Postpone this event until after a state change
  Postpone

  /// Insert a new event at the front of the queue
  NextEvent(content: message)

  /// Set a state timeout (canceled on state change)
  StateTimeout(milliseconds: Int)

  /// Set a generic named timeout
  GenericTimeout(name: String, milliseconds: Int)

  /// Cancel the running state timeout before it fires.
  /// Since OTP 22.1.
  CancelStateTimeout

  /// Cancel a running named generic timeout before it fires.
  /// Since OTP 22.1.
  CancelGenericTimeout(name: String)

  /// Update the payload delivered when the state timeout fires,
  /// without restarting the timer. Since OTP 22.1.
  UpdateStateTimeout(content: message)

  /// Update the payload delivered when a named generic timeout fires,
  /// without restarting the timer. Since OTP 22.1.
  UpdateGenericTimeout(name: String, content: message)

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
pub type RequestId(reply)

/// A collection of in-flight request IDs, each associated with a `label`.
///
/// Used with `send_request_to_collection`, `request_ids_add`, and
/// `receive_response_collection` to manage multiple concurrent requests.
/// Requires Erlang/OTP 25.0 or later.
///
pub type RequestIdCollection(label, reply)

/// Whether `receive_response_collection` removes the matched request from
/// the collection after delivering the reply.
///
pub type ResponseHandling {
  Delete
  Keep
}

/// Reasons `receive_response` and `receive_response_collection` can fail.
///
pub type ReceiveError {
  /// No reply was received within the timeout.
  ReceiveTimeout
  /// The server handling the request crashed or went away.
  RequestCrashed(reason: StopReason)
}

/// The result of waiting for a response from a `RequestIdCollection`.
///
pub type CollectionResponse(reply, label) {
  /// A successful reply was received for one of the pending requests.
  GotReply(
    reply: reply,
    label: label,
    remaining: RequestIdCollection(label, reply),
  )

  /// One of the requests returned an error (e.g. the server crashed).
  RequestFailed(
    reason: StopReason,
    label: label,
    remaining: RequestIdCollection(label, reply),
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
) -> Builder(state, data, message, Subject(message), reply) {
  Builder(
    initial_state: initial_state,
    initial_data: initial_data,
    event_handler: fn(_, _state, data) { keep_state(data, []) },
    state_enter: StateEnterDisabled,
    initialisation_timeout: 1000,
    name: None,
    on_code_change: None,
    on_format_status: None,
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
/// fn handle_event(event, _state, data) {
///   case event {
///     Call(from, GetCount) -> reply_and_keep(from, data.count, data)
///     Cast(Increment) -> keep_state(Data(..data, count: data.count + 1), [])
///     Call(_, _) -> keep_state(data, [])
///     Cast(_) -> keep_state(data, [])
///     Info(_) -> keep_state(data, [])
///     Enter(_) -> keep_state(data, [])
///     Timeout(_) -> keep_state(data, [])
///   }
/// }
///
/// state_machine.new(Running, Data(0))
/// |> state_machine.on_event(handle_event)
/// |> state_machine.start
/// ```
///
pub fn on_event(
  builder: Builder(state, data, message, return, reply),
  handler: fn(Event(state, message, reply), state, data) ->
    Step(state, data, message, reply),
) -> Builder(state, data, message, return, reply) {
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
/// fn handle_event(event, _state, data) {
///   case event {
///     Enter(_old) -> keep_state(data, [StateTimeout(30_000)])
///     Call(_, _) -> keep_state(data, [])
///     Cast(_) -> keep_state(data, [])
///     Info(_) -> keep_state(data, [])
///     Timeout(_) -> keep_state(data, [])
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
  builder: Builder(state, data, message, return, reply),
) -> Builder(state, data, message, return, reply) {
  Builder(..builder, state_enter: StateEnterEnabled)
}

/// Provide a name for the state machine to be registered with when started.
///
/// This enables sending messages to it via a named subject.
///
pub fn named(
  builder: Builder(state, data, message, return, reply),
  name: process.Name(message),
) -> Builder(state, data, message, return, reply) {
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
  builder: Builder(state, data, message, return, reply),
  handler: fn(data) -> data,
) -> Builder(state, data, message, return, reply) {
  Builder(..builder, on_code_change: Some(handler))
}

/// Provide a formatter called when `sys:get_status/1` or SASL crash reports
/// render the state machine.
///
/// Maps to OTP's [`format_status/1`](https://www.erlang.org/doc/apps/stdlib/gen_statem.html#c:format_status/1)
/// gen_statem callback. The formatter receives a `Status` value containing
/// the current state and data (plus optional fields described on the
/// `Status` type) and returns a transformed `Status`. Use this to redact
/// sensitive fields or produce a more readable representation.
///
/// If not set, `sys:get_status/1` receives the raw internal state without
/// transformation.
///
/// ## Example
///
/// ```gleam
/// state_machine.new(initial_state: Idle, initial_data: Credentials("secret"))
/// |> state_machine.on_format_status(fn(status) {
///   Status(..status, data: Credentials("<redacted>"))
/// })
/// |> state_machine.on_event(handle_event)
/// |> state_machine.start
/// ```
///
pub fn on_format_status(
  builder: Builder(state, data, message, return, reply),
  formatter: fn(Status(state, data, message, reply)) ->
    Status(state, data, message, reply),
) -> Builder(state, data, message, return, reply) {
  Builder(..builder, on_format_status: Some(formatter))
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
  builder: Builder(state, data, message, Subject(message), reply),
) -> StartResult(Subject(message)) {
  let Builder(
    initial_state:,
    initial_data:,
    event_handler:,
    state_enter:,
    initialisation_timeout:,
    name:,
    on_code_change:,
    on_format_status:,
  ) = builder
  do_start(
    initial_state,
    initial_data,
    event_handler,
    state_enter,
    initialisation_timeout,
    name,
    on_code_change,
    on_format_status,
  )
}

@external(erlang, "statem_ffi", "do_start")
fn do_start(
  initial_state: state,
  initial_data: data,
  event_handler: fn(Event(state, message, reply), state, data) ->
    Step(state, data, message, reply),
  state_enter: StateEnter,
  initialisation_timeout: Int,
  name: Option(process.Name(message)),
  on_code_change: Option(fn(data) -> data),
  on_format_status: Option(
    fn(Status(state, data, message, reply)) ->
      Status(state, data, message, reply),
  ),
) -> Result(Started(Subject(message)), StartError)

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
  actions: List(Action(message, reply)),
) -> Step(state, data, message, reply) {
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
  actions: List(Action(message, reply)),
) -> Step(state, data, message, reply) {
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
pub fn stop(reason: ExitReason) -> Step(state, data, message, reply) {
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
pub fn reply(from: From(reply), response: reply) -> Action(message, reply) {
  Reply(from:, response:)
}

/// Create a Postpone action.
///
/// Postpones the current event until after the next state change.
///
pub fn postpone() -> Action(message, reply) {
  Postpone
}

/// Create a NextEvent action.
///
/// Inserts a new event at the front of the event queue.
///
pub fn next_event(content: message) -> Action(message, reply) {
  NextEvent(content:)
}

/// Create a StateTimeout action.
///
/// Sets a timeout that is automatically canceled when the state changes.
///
pub fn state_timeout(milliseconds: Int) -> Action(message, reply) {
  StateTimeout(milliseconds:)
}

/// Create a GenericTimeout action.
///
/// Sets a named timeout that persists across state changes.
///
pub fn generic_timeout(
  name: String,
  milliseconds: Int,
) -> Action(message, reply) {
  GenericTimeout(name:, milliseconds:)
}

/// Cancel the running state timeout before it fires.
///
pub fn cancel_state_timeout() -> Action(message, reply) {
  CancelStateTimeout
}

/// Cancel a running named generic timeout before it fires.
///
pub fn cancel_generic_timeout(name: String) -> Action(message, reply) {
  CancelGenericTimeout(name:)
}

/// Update the payload of the running state timeout without restarting the timer.
///
pub fn update_state_timeout(content: message) -> Action(message, reply) {
  UpdateStateTimeout(content:)
}

/// Update the payload of a running named generic timeout without restarting the timer.
///
pub fn update_generic_timeout(
  name: String,
  content: message,
) -> Action(message, reply) {
  UpdateGenericTimeout(name:, content:)
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
pub fn change_callback_module(module: Atom) -> Action(message, reply) {
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
pub fn push_callback_module(module: Atom) -> Action(message, reply) {
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
pub fn pop_callback_module() -> Action(message, reply) {
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
) -> Step(state, data, message, reply) {
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
) -> Step(state, data, message, reply) {
  KeepState(data:, actions: [Reply(from:, response:)])
}

/// Send a message to a state machine via `process.send` (arrives as `Info`).
///
/// The message is delivered to the handler as `Info(message)`. Use this for
/// messages sent from processes that are not aware of this library, e.g.
/// monitors, timers, or plain Erlang processes.
///
/// To deliver messages as `Cast(message)` instead, use `cast/2`.
///
pub fn send(subject: Subject(message), message: message) -> Nil {
  process.send(subject, message)
}

/// Send an asynchronous cast to a state machine (arrives as `Cast`).
///
/// Unlike `send`, which routes messages through `process.send` and delivers
/// them as `Info(message)`, this function calls `gen_statem:cast` so messages
/// arrive as `Cast(message)` in the event handler.
///
/// Use `cast` when you want to distinguish machine-level commands from
/// ambient info messages (monitors, raw Erlang signals, etc.).
///
/// ## Example
///
/// ```gleam
/// fn handle_event(event, _state, data) {
///   case event {
///     Cast(Increment) -> keep_state(data + 1, [])
///     Cast(_) -> keep_state(data, [])
///     Info(_) -> keep_state(data, []) // ignore ambient noise
///     Call(_, _) -> keep_state(data, [])
///     Enter(_) -> keep_state(data, [])
///     Timeout(_) -> keep_state(data, [])
///   }
/// }
/// ```
///
@external(erlang, "statem_ffi", "cast")
pub fn cast(subject: Subject(message), message: message) -> Nil

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

// request-id API (OTP 25.0+)

/// Create a new, empty request-id collection.
///
/// Used with `send_request_to_collection` to batch multiple async requests and
/// then receive them through `receive_response_collection`.
///
/// Requires Erlang/OTP 25.0 or later.
///
@external(erlang, "statem_ffi", "reqids_new")
pub fn request_ids_new() -> RequestIdCollection(label, reply)

/// Add a `RequestId` to a collection under a `label`.
///
/// The label is returned alongside the reply in `receive_response_collection`,
/// letting you identify which request the response belongs to.
///
/// Requires Erlang/OTP 25.0 or later.
///
@external(erlang, "statem_ffi", "reqids_add")
pub fn request_ids_add(
  request_id request_id: RequestId(reply),
  label label: label,
  to collection: RequestIdCollection(label, reply),
) -> RequestIdCollection(label, reply)

/// Return the number of pending request IDs in a collection.
///
/// Requires Erlang/OTP 25.0 or later.
///
@external(erlang, "statem_ffi", "reqids_size")
pub fn request_ids_size(collection: RequestIdCollection(label, reply)) -> Int

/// Convert a collection to a list of `#(RequestId, label)` pairs.
///
/// Requires Erlang/OTP 25.0 or later.
///
@external(erlang, "statem_ffi", "reqids_to_list")
pub fn request_ids_to_list(
  collection: RequestIdCollection(label, reply),
) -> List(#(RequestId(reply), label))

/// Send an asynchronous call to a state machine and return a `RequestId`.
///
/// Unlike `call`, this does not block. Use `receive_response` later to
/// collect the reply. The server receives a `Call(from, message)` event
/// and must reply with a `Reply(from, value)` action.
///
/// The `reply` type cannot always be inferred, so annotate the binding when
/// needed: `let request: RequestId(MyReply) = send_request(subject, MyMsg)`
///
/// ## Example
///
/// ```gleam
/// let request: state_machine.RequestId(Int) =
///   state_machine.send_request(machine.data, GetCount)
/// // ... do other work ...
/// let assert Ok(count) = state_machine.receive_response(request, 1000)
/// ```
///
/// Requires Erlang/OTP 25.0 or later.
///
@external(erlang, "statem_ffi", "send_request")
pub fn send_request(
  subject: Subject(message),
  message: message,
) -> RequestId(reply)

/// Send an asynchronous call and immediately add the `RequestId` to a
/// collection.
///
/// Equivalent to calling `send_request` and `request_ids_add` in one step.
/// Useful for issuing several requests in a loop before waiting for any of
/// them.
///
/// ## Example
///
/// ```gleam
/// let collection: state_machine.RequestIdCollection(String, Int) =
///   state_machine.request_ids_new()
/// let collection =
///   state_machine.send_request_to_collection(sub, GetCount, "first", collection)
/// let collection =
///   state_machine.send_request_to_collection(sub, GetCount, "second", collection)
/// // ... receive responses via receive_response_collection ...
/// ```
///
/// Requires Erlang/OTP 25.0 or later.
///
@external(erlang, "statem_ffi", "send_request_to_collection")
pub fn send_request_to_collection(
  subject: Subject(message),
  message: message,
  label: label,
  to collection: RequestIdCollection(label, reply),
) -> RequestIdCollection(label, reply)

/// Wait up to `timeout` milliseconds for the reply to a single `RequestId`.
///
/// Returns `Ok(reply)` on success, `Error(ReceiveTimeout)` if no reply
/// arrives in time, or `Error(RequestCrashed(reason))` if the server
/// terminated before replying.
///
/// Requires Erlang/OTP 25.0 or later.
///
@external(erlang, "statem_ffi", "receive_response")
pub fn receive_response(
  request_id: RequestId(reply),
  timeout: Int,
) -> Result(reply, ReceiveError)

/// Wait up to `timeout` milliseconds for any pending reply in a collection.
///
/// Pass `Delete` to remove the matched request from the returned collection,
/// or `Keep` to retain it. Call this in a loop to drain all responses one by
/// one.
///
/// ## Example
///
/// ```gleam
/// let assert state_machine.GotReply(value, label, collection) =
///   state_machine.receive_response_collection(collection, 1000, state_machine.Delete)
/// ```
///
/// Requires Erlang/OTP 25.0 or later.
///
@external(erlang, "statem_ffi", "receive_response_collection")
pub fn receive_response_collection(
  collection: RequestIdCollection(label, reply),
  timeout: Int,
  handling: ResponseHandling,
) -> CollectionResponse(reply, label)
