//// A type-safe, OTP-compatible event manager implementation that leverages
//// Erlang's [gen_event](https://www.erlang.org/doc/apps/stdlib/gen_event.html)
//// behaviour through the [Gleam FFI](https://gleam.run/documentation/externals/#Erlang-externals).
////
//// ## Overview
////
//// An event manager is a process that hosts any number of independent
//// **handlers**. Handlers are attached and detached at runtime. When you call
//// `notify` or `sync_notify`, every currently-registered handler receives the
//// event.
////
//// ## Example
////
//// ```gleam
//// import eparch/event_manager
//// import gleam/erlang/process
////
//// type MyEvent { LogLine(String) | Flush(process.Subject(Nil)) }
////
//// case event_manager.start() {
////   Ok(manager) -> {
////     let handler =
////       event_manager.new_handler(0, fn(event, count) {
////         case event {
////           LogLine(_) -> event_manager.Continue(count + 1)
////           Flush(reply) -> {
////             process.send(reply, Nil)
////             event_manager.Continue(count)
////           }
////         }
////       })
////     let _ = event_manager.add_handler(manager, handler)
////     event_manager.notify(manager, LogLine("hello"))
////     event_manager.sync_notify(manager, LogLine("world"))
////   }
////   Error(_) -> Nil
//// }
//// ```

import gleam/erlang/process.{type Monitor, type Name, type Pid}
import gleam/option.{type Option, None, Some}

/// The result of a handler processing an event.
///
/// Return `Continue(new_state)` to keep the handler alive with updated state,
/// or `Remove` to unregister the handler from the manager.
///
pub type EventStep(state) {
  /// Keep the handler alive and update its state.
  Continue(state: state)

  /// Remove this handler from the event manager.
  Remove
}

/// Errors that can occur when starting an event manager.
pub type StartError {
  /// A manager with the requested registered name is already running.
  /// The field carries the Pid of the already-running manager so callers can
  /// reuse it or diagnose the conflict.
  AlreadyStarted(pid: Pid)
  /// Startup failed for another reason. `reason` is a human-readable string
  /// produced from the raw Erlang error term.
  StartFailed(reason: String)
}

/// A timeout: either a fixed number of milliseconds or `Infinity`.
pub type Timeout {
  Infinity
  Milliseconds(ms: Int)
}

/// Process priority for `SpawnPriority`.
pub type Priority {
  PriorityLow
  PriorityNormal
  PriorityHigh
  PriorityMax
}

/// Message queue storage mode for `SpawnMessageQueueData`.
pub type MessageQueueMode {
  OnHeap
  OffHeap
}

/// Flags for the `debug` option of `StartOptions`.
pub type DebugFlag {
  DebugTrace
  DebugLog
  DebugStatistics
  DebugLogToFile(file_name: String)
}

/// Flags for the `spawn_options` option of `StartOptions`. Subset of
/// `erlang:spawn_opt/2`'s options that are meaningful for a long-running
/// server process. `link` and `monitor` are intentionally omitted — the
/// manager is always linked (and optionally monitored) by the `start` /
/// `start_monitor` entry points themselves.
pub type SpawnOption {
  SpawnPriority(level: Priority)
  SpawnFullsweepAfter(count: Int)
  SpawnMinHeapSize(size: Int)
  SpawnMinBinVheapSize(size: Int)
  SpawnMaxHeapSize(size: Int)
  SpawnMessageQueueData(mode: MessageQueueMode)
}

/// Options for `start_monitor`. Build a value with `new_start_options()` and
/// extend it using the `with_*` setter functions.
///
pub opaque type StartOptions(event) {
  StartOptions(
    name: Option(Name(event)),
    timeout: Timeout,
    hibernate_after: Timeout,
    debug: List(DebugFlag),
    spawn_options: List(SpawnOption),
  )
}

/// Data returned when a manager is started with `start_monitor`.
pub type MonitoredManager(event) {
  MonitoredManager(manager: Manager(event), monitor: Monitor)
}

/// Errors that can occur when adding a handler.
pub type AddError {
  /// A handler with the same identity is already registered. The field
  /// carries the `HandlerRef` that caused the collision.
  HandlerAlreadyExists(handler_ref: HandlerRef)
  /// The handler's initialisation failed. `reason` is a human-readable
  /// string produced from the raw Erlang error term.
  InitFailed(reason: String)
}

/// Errors that can occur when removing a handler.
pub type RemoveError {
  /// No handler with the given ref is currently registered. The field
  /// carries the `HandlerRef` the caller supplied.
  HandlerNotFound(handler_ref: HandlerRef)
  /// Removal failed for another reason.
  RemoveFailed(reason: String)
}

/// A builder for configuring a handler before registering it with a manager.
///
/// Create one with `new_handler/2` and optionally extend it with
/// `on_terminate/2` and `on_format_status/2`.
///
pub opaque type Handler(state, event) {
  Handler(
    init_state: state,
    on_event: fn(event, state) -> EventStep(state),
    on_terminate: Option(fn(state) -> Nil),
    on_format_status: Option(fn(state) -> String),
  )
}

/// An opaque reference to a specific registered handler instance.
///
/// Values of this type are only ever produced by `add_handler` or
/// `add_supervised_handler`. Pass them to `remove_handler` to unregister a
/// specific handler, or compare them with values returned by `which_handlers`.
///
pub type HandlerRef

/// An opaque reference to a running event manager process.
///
/// Values of this type are produced by `start` (directly) and `start_monitor`
/// (as the `manager` field of the returned `MonitoredManager`). Pass them to
/// `notify`, `sync_notify`, `add_handler`, etc.
///
pub type Manager(event)

/// Handler Builder
///
/// Create a handler with an initial state and an event callback.
///
/// The `on_event` function is called for every event delivered to this handler
/// via `notify` or `sync_notify`. It receives the event and the current state,
/// and must return either `Continue(new_state)` or `Remove`.
///
/// ## Example
///
/// ```gleam
/// let handler =
///   event_manager.new_handler(initial_state: 0, on_event: fn(event, count) {
///     case event {
///       Increment -> event_manager.Continue(count + 1)
///       Reset     -> event_manager.Continue(0)
///     }
///   })
/// ```
///
pub fn new_handler(
  initial_state initial_state: state,
  on_event handler: fn(event, state) -> EventStep(state),
) -> Handler(state, event) {
  Handler(
    init_state: initial_state,
    on_event: handler,
    on_terminate: None,
    on_format_status: None,
  )
}

/// Attach a cleanup function called when the handler is removed or the manager
/// stops.
///
/// ## Example
///
/// ```gleam
/// event_manager.new_handler(connection, on_event)
/// |> event_manager.on_terminate(fn(connection) { db.close(connection) })
/// ```
///
pub fn on_terminate(
  handler: Handler(state, event),
  cleanup: fn(state) -> Nil,
) -> Handler(state, event) {
  Handler(..handler, on_terminate: Some(cleanup))
}

/// Provide a function to format this handler's state for OTP status reports.
///
/// When set, the returned string is used in place of the raw state in
/// `sys:get_status/1` output and SASL crash reports. Useful for hiding
/// secrets, summarising large data structures, or presenting a domain-friendly
/// view. Since OTP 25.0.
///
/// ## Example
///
/// ```gleam
/// event_manager.new_handler(connection, on_event)
/// |> event_manager.on_format_status(fn(connection) {
///   "Conn(id=" <> connection.id <> ")"
/// })
/// ```
///
pub fn on_format_status(
  handler: Handler(state, event),
  formatter: fn(state) -> String,
) -> Handler(state, event) {
  Handler(..handler, on_format_status: Some(formatter))
}

// ---------------------------------------------------------------------------
// StartOptions builder
// ---------------------------------------------------------------------------
/// Build a fresh `StartOptions` with defaults: no registered name, `Infinity`
/// for both `timeout` and `hibernate_after`, no debug flags, no spawn options.
///
pub fn new_start_options() -> StartOptions(event) {
  StartOptions(
    name: None,
    timeout: Infinity,
    hibernate_after: Infinity,
    debug: [],
    spawn_options: [],
  )
}

/// Register the manager under a local name. Gives callers a
/// `process.Name(event)` they can turn into a `Subject` or look up with
/// `process.named/1`.
///
pub fn with_name(
  options: StartOptions(event),
  name: Name(event),
) -> StartOptions(event) {
  StartOptions(..options, name: Some(name))
}

/// Set the initialisation timeout. Passed through to gen_event as the
/// `{timeout, _}` option.
///
pub fn with_timeout(
  options: StartOptions(event),
  timeout: Timeout,
) -> StartOptions(event) {
  StartOptions(..options, timeout: timeout)
}

/// Set the idle hibernation timeout. Passed through to gen_event as the
/// `{hibernate_after, _}` option.
///
pub fn with_hibernate_after(
  options: StartOptions(event),
  timeout: Timeout,
) -> StartOptions(event) {
  StartOptions(..options, hibernate_after: timeout)
}

/// Set the sys debug flags for the manager.
///
pub fn with_debug(
  options: StartOptions(event),
  flags: List(DebugFlag),
) -> StartOptions(event) {
  StartOptions(..options, debug: flags)
}

/// Set the `erlang:spawn_opt/2` options forwarded to the manager process.
///
pub fn with_spawn_options(
  options: StartOptions(event),
  spawn_options: List(SpawnOption),
) -> StartOptions(event) {
  StartOptions(..options, spawn_options: spawn_options)
}

// ---------------------------------------------------------------------------
// Manager lifecycle
// ---------------------------------------------------------------------------

/// Start an event manager process linked to the caller.
///
/// ## Example
///
/// ```gleam
/// case event_manager.start() {
///   Ok(manager) -> {
///     // ... use manager ...
///     event_manager.stop(manager)
///   }
///   Error(_) -> Nil
/// }
/// ```
///
pub fn start() -> Result(Manager(event), StartError) {
  do_start()
}

@external(erlang, "event_manager_ffi", "do_start")
fn do_start() -> Result(Manager(event), StartError)

/// Start an event manager linked to the caller and atomically return a
/// monitor for it.
///
/// Equivalent to calling `start()` followed by `process.monitor(manager_pid)`,
/// but without the race window between the two calls. The returned
/// `MonitoredManager` carries both the `Manager` and a `process.Monitor` you
/// can select on. Since OTP 23.0.
///
/// ## Example
///
/// ```gleam
/// case event_manager.start_monitor(event_manager.new_start_options()) {
///   Ok(monitored) -> {
///     let selector =
///       process.new_selector()
///       |> process.select_specific_monitor(monitored.monitor, fn(down) { down })
///     // ... use monitored.manager, wait on `selector` for a Down message ...
///   }
///   Error(_) -> Nil
/// }
/// ```
///
pub fn start_monitor(
  options: StartOptions(event),
) -> Result(MonitoredManager(event), StartError) {
  do_start_monitor(options)
}

@external(erlang, "event_manager_ffi", "do_start_monitor")
fn do_start_monitor(
  options: StartOptions(event),
) -> Result(MonitoredManager(event), StartError)

/// Stop the event manager, terminating it with reason `normal`.
///
/// All registered handlers have their `on_terminate` callback invoked before
/// the manager shuts down.
///
pub fn stop(manager: Manager(event)) -> Nil {
  do_stop(manager)
}

@external(erlang, "event_manager_ffi", "do_stop")
fn do_stop(manager: Manager(event)) -> Nil

/// Return the Pid of the event manager process.
///
/// Useful for monitoring the manager with `process.monitor` when you did not
/// start it via `start_monitor`.
///
pub fn manager_pid(manager: Manager(event)) -> Pid {
  do_manager_pid(manager)
}

@external(erlang, "event_manager_ffi", "do_manager_pid")
fn do_manager_pid(manager: Manager(event)) -> Pid

// ---------------------------------------------------------------------------
// Handler management
// ---------------------------------------------------------------------------

/// Register an unsupervised handler with the event manager.
///
/// Returns `Ok(HandlerRef)` on success. The returned ref uniquely identifies
/// this handler instance and can be used with `remove_handler`.
///
/// If the handler crashes, the manager removes it silently without notifying
/// the caller. For crash notifications use `add_supervised_handler`.
///
/// ## Example
///
/// ```gleam
/// case event_manager.add_handler(manager, my_handler) {
///   Ok(handler_ref) -> // use handler_ref later with remove_handler
///   Error(_) -> Nil
/// }
/// ```
///
pub fn add_handler(
  manager: Manager(event),
  handler: Handler(state, event),
) -> Result(HandlerRef, AddError) {
  do_add_handler(manager, handler)
}

@external(erlang, "event_manager_ffi", "do_add_handler")
fn do_add_handler(
  manager: Manager(event),
  handler: Handler(state, event),
) -> Result(HandlerRef, AddError)

/// Register a supervised handler with the event manager.
///
/// Like `add_handler`, but links the handler to the calling process. If the
/// handler is removed for any reason other than a normal `remove_handler` call
/// (e.g. it crashes or returns `Remove`), the calling process receives an
/// Erlang message shaped like:
///
/// ```
/// {gen_event_EXIT, HandlerRef, Reason}
/// ```
///
/// Receive it via `gleam/erlang/process` selectors — `process.select_other` is
/// the catch-all hook you can use to observe raw Erlang messages.
///
pub fn add_supervised_handler(
  manager: Manager(event),
  handler: Handler(state, event),
) -> Result(HandlerRef, AddError) {
  do_add_supervised_handler(manager, handler)
}

@external(erlang, "event_manager_ffi", "do_add_sup_handler")
fn do_add_supervised_handler(
  manager: Manager(event),
  handler: Handler(state, event),
) -> Result(HandlerRef, AddError)

/// Remove a specific handler from the event manager.
///
/// The handler's `on_terminate` callback is called before removal.
///
pub fn remove_handler(
  manager: Manager(event),
  handler_ref: HandlerRef,
) -> Result(Nil, RemoveError) {
  do_remove_handler(manager, handler_ref)
}

@external(erlang, "event_manager_ffi", "do_remove_handler")
fn do_remove_handler(
  manager: Manager(event),
  handler_ref: HandlerRef,
) -> Result(Nil, RemoveError)

/// Return the list of `HandlerRef`s for all currently registered handlers.
///
pub fn which_handlers(manager: Manager(event)) -> List(HandlerRef) {
  do_which_handlers(manager)
}

@external(erlang, "event_manager_ffi", "do_which_handlers")
fn do_which_handlers(manager: Manager(event)) -> List(HandlerRef)

// ---------------------------------------------------------------------------
// Notifications
// ---------------------------------------------------------------------------

/// Asynchronously broadcast an event to all registered handlers.
///
/// Returns immediately without waiting for handlers to finish processing.
/// Use `sync_notify` if you need a synchronization point.
///
pub fn notify(manager: Manager(event), event: event) -> Nil {
  do_notify(manager, event)
}

@external(erlang, "event_manager_ffi", "do_notify")
fn do_notify(manager: Manager(event), event: event) -> Nil

/// Synchronously broadcast an event to all registered handlers.
///
/// Blocks until every currently registered handler has processed the event.
/// Use this when you need to know that all handlers have seen the event before
/// continuing.
///
pub fn sync_notify(manager: Manager(event), event: event) -> Nil {
  do_sync_notify(manager, event)
}

@external(erlang, "event_manager_ffi", "do_sync_notify")
fn do_sync_notify(manager: Manager(event), event: event) -> Nil
