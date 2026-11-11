//// Broadcast events to independently scheduled handler actors. Membership is
//// sampled when the manager processes a publication. Each recipient sees that
//// manager's broadcasts in FIFO order; callbacks on different actors can run
//// in either order. A confirmation observes processing, not durable storage.
////
//// Only confirmation bookkeeping is bounded (`with_max_in_flight_sync`).
//// Worker mailboxes are not: `notify` applies no backpressure, so a slow
//// handler accumulates every event published to it.
////
//// ## Example
////
//// ```gleam
//// let assert Ok(manager) = event_manager.start_link(event_manager.new_start_options())
//// let printer =
////   event_manager.new_handler(Nil, fn(event, state) {
////     io.println(event)
////     event_manager.Continue(state)
////   })
//// let assert Ok(_ref) = event_manager.add_handler(manager, printer, on_down: None)
//// event_manager.notify(manager, "hello")
//// let assert event_manager.Confirmed =
////   event_manager.sync_notify(manager, "flushed", 1000)
//// ```

import gleam/dict.{type Dict}
import gleam/erlang/process.{type ExitReason, type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/set.{type Set}

/// A callback may update its private state or retire its instance.
pub type EventStep(state) {
  /// Keep handling events with the new state.
  Continue(state)
  /// Run the cleanup callback and stop this handler instance.
  Remove
}

/// Identity of one subscription; a ref from another manager cannot match.
pub opaque type HandlerId {
  HandlerId(pid: Pid)
}

/// A capability for one handler instance.
pub opaque type HandlerRef(event) {
  HandlerRef(id: HandlerId, inbox: Subject(Envelope(event)))
}

/// Handler configuration. Only the worker executes user code.
pub opaque type Handler(state, event) {
  Handler(
    initial: state,
    handle: fn(event, state) -> EventStep(state),
    cleanup: fn(state) -> Nil,
  )
}

/// Notification of abnormal worker termination.
pub type HandlerDown {
  HandlerDown(id: HandlerId, reason: ExitReason)
}

@external(erlang, "eparch_delivery_ffi", "notify_observer")
fn notify_observer(observer: Subject(HandlerDown), event: HandlerDown) -> Nil

@external(erlang, "eparch_delivery_ffi", "exit_with")
fn exit_with(reason: ExitReason) -> a

type Waiter(value)

type WaitError {
  WaitTimeout
  WaitDown
}

@external(erlang, "eparch_delivery_ffi", "request")
fn request(
  pid: Pid,
  timeout: Int,
  send: fn(Waiter(value), Int) -> Nil,
) -> Result(value, WaitError)

@external(erlang, "eparch_delivery_ffi", "respond")
fn respond(to: Waiter(value), value: value) -> Nil

@external(erlang, "eparch_delivery_ffi", "now_ms")
fn now_ms() -> Int

/// The outcome of `sync_notify`.
///
/// A timeout does not cancel dispatch. `SyncBusy` and `SyncReentrant` mean
/// no dispatch took place.
pub type SyncResult {
  /// Every handler in the acceptance snapshot processed the event.
  Confirmed
  /// These handlers exited before acknowledging; the rest processed it.
  Unconfirmed(handlers: List(HandlerId))
  /// The caller's wait expired. The event may still be processed.
  SyncTimeout
  /// The manager already tracks `with_max_in_flight_sync` confirmations.
  SyncBusy
  /// The caller is itself an enrolled handler and would wait on itself.
  SyncReentrant
  /// The manager was not running, or exited before answering.
  SyncManagerDown
}

/// Why the manager could not be started.
pub type StartError =
  actor.StartError

/// Why `add_handler` or `replace_handler` failed.
pub type AddError {
  /// The manager was not running, or exited before answering.
  AddManagerDown
  /// The handler worker could not be started.
  HandlerStartFailed(reason: StartError)
  /// `replace_handler` was given a ref that is no longer a member.
  StaleRef
}

/// Why `remove_handler` could not confirm removal.
pub type RemoveError {
  /// The ref is not a current member of this manager.
  HandlerNotFound
  /// Removal was accepted but draining did not finish in time. Removal is
  /// not rolled back.
  RemoveTimedOut
  /// The worker exited (for example, its cleanup crashed) before it
  /// finished draining.
  DrainInterrupted
  /// The manager was not running, or exited before answering.
  RemoveManagerDown
}

/// Why `stop` could not confirm acceptance.
pub type StopError {
  /// The manager was not running.
  AlreadyStopped
  /// The manager did not accept the stop request in time.
  StopTimedOut
}

/// Start-time configuration for a manager.
pub opaque type StartOptions {
  StartOptions(init_timeout: Int, max_in_flight_sync: Int)
}

/// Defaults: a 5000 ms initialisation timeout and at most 64 in-flight
/// synchronous publications.
///
/// ## Example
///
/// ```gleam
/// event_manager.new_start_options()
/// |> event_manager.with_max_in_flight_sync(8)
/// |> event_manager.start_link
/// ```
///
pub fn new_start_options() -> StartOptions {
  StartOptions(init_timeout: 5000, max_in_flight_sync: 64)
}

/// Set how long `start*` waits for the manager to initialise. Negative
/// values are treated as 0.
///
/// ## Example
///
/// ```gleam
/// event_manager.new_start_options() |> event_manager.with_init_timeout(1000)
/// ```
///
pub fn with_init_timeout(options: StartOptions, timeout: Int) -> StartOptions {
  StartOptions(..options, init_timeout: int.max(timeout, 0))
}

/// Bounds confirmation bookkeeping, not worker mailboxes. Zero rejects all
/// synchronous publications with `SyncBusy`; negative values are treated as
/// 0.
///
/// ## Example
///
/// ```gleam
/// event_manager.new_start_options()
/// |> event_manager.with_max_in_flight_sync(1)
/// ```
///
pub fn with_max_in_flight_sync(
  options: StartOptions,
  max: Int,
) -> StartOptions {
  StartOptions(..options, max_in_flight_sync: int.max(max, 0))
}

/// A running manager that broadcasts values of type `event`.
pub opaque type Manager(event) {
  Manager(pid: Pid, subject: Subject(Command(event)))
}

type Envelope(event) {
  Deliver(event, Option(Waiter(SyncResult)))
  Drain
}

type Entry(event) {
  Entry(ref: HandlerRef(event), on_down: Option(Subject(HandlerDown)))
}

type DrainWaiter =
  Waiter(Result(Nil, RemoveError))

type Retiring(event) {
  Retiring(entry: Entry(event), waiter: Option(DrainWaiter))
}

type Receipt {
  Acknowledged
  Lost
}

type Pending {
  Pending(
    remaining: Set(HandlerId),
    lost: List(HandlerId),
    expiry: process.Timer,
    deadline: Int,
  )
}

type Command(event) {
  Install(
    replacing: Option(HandlerId),
    spawn: fn() -> Result(Entry(event), StartError),
    reply: Subject(Result(HandlerRef(event), AddError)),
  )
  Retire(id: HandlerId, reply: DrainWaiter)
  Drained(id: HandlerId)
  Which(reply: Subject(List(HandlerId)))
  Notify(event: event)
  Sync(event: event, caller: Pid, deadline: Int, reply: Waiter(SyncResult))
  Ack(key: Waiter(SyncResult), id: HandlerId)
  Expire(key: Waiter(SyncResult))
  Exited(message: process.ExitMessage)
  Shutdown(reply: Waiter(Nil))
}

type Registry(event) {
  Registry(
    inbox: Subject(Command(event)),
    parent: Option(Pid),
    active: List(Entry(event)),
    retiring: Dict(HandlerId, Retiring(event)),
    pending: Dict(Waiter(SyncResult), Pending),
    max_in_flight_sync: Int,
  )
}

type LinkMode {
  Linked
  Unlinked
}

/// Start a manager linked to the caller. When the caller exits, the manager
/// kills its workers and exits with the same reason, as an OTP child should.
///
/// ## Example
///
/// ```gleam
/// let assert Ok(manager) =
///   event_manager.start_link(event_manager.new_start_options())
/// ```
///
pub fn start_link(options: StartOptions) -> Result(Manager(event), StartError) {
  launch(options, Linked)
}

/// Start a manager that is not linked to the caller.
///
/// ## Example
///
/// ```gleam
/// let assert Ok(manager) = event_manager.start(event_manager.new_start_options())
/// ```
///
pub fn start(options: StartOptions) -> Result(Manager(event), StartError) {
  launch(options, Unlinked)
}

/// Starts unlinked and monitors the returned pid; death before the monitor is
/// installed is observed as a down notification for a missing process.
///
/// ## Example
///
/// ```gleam
/// let assert Ok(#(manager, monitor)) =
///   event_manager.start_monitor(event_manager.new_start_options())
/// ```
///
pub fn start_monitor(
  options: StartOptions,
) -> Result(#(Manager(event), process.Monitor), StartError) {
  use manager <- result.map(start(options))
  #(manager, process.monitor(manager.pid))
}

fn launch(
  options: StartOptions,
  link_mode: LinkMode,
) -> Result(Manager(event), StartError) {
  let caller = process.self()
  use started <- result.map(
    actor.new_with_initialiser(options.init_timeout, fn(inbox) {
      process.trap_exits(True)
      let parent = case link_mode {
        Linked -> Some(caller)
        Unlinked -> {
          process.unlink(caller)
          None
        }
      }
      Ok(
        actor.initialised(Registry(
          inbox: inbox,
          parent: parent,
          active: [],
          retiring: dict.new(),
          pending: dict.new(),
          max_in_flight_sync: options.max_in_flight_sync,
        ))
        |> actor.selecting(
          process.new_selector()
          |> process.select(inbox)
          |> process.select_trapped_exits(Exited),
        )
        |> actor.returning(inbox),
      )
    })
    |> actor.on_message(handle)
    |> actor.start,
  )
  Manager(started.pid, started.data)
}

fn handle(
  registry: Registry(event),
  command: Command(event),
) -> actor.Next(Registry(event), Command(event)) {
  case command {
    Install(replacing, spawn, reply) -> {
      let previous =
        option.then(replacing, fn(id) {
          find_active(registry, id) |> option.from_result
        })
      case replacing, previous {
        Some(_), None -> {
          process.send(reply, Error(StaleRef))
          actor.continue(registry)
        }
        None, _ | Some(_), Some(_) ->
          case spawn() {
            Error(reason) -> {
              process.send(reply, Error(HandlerStartFailed(reason)))
              actor.continue(registry)
            }
            Ok(entry) -> {
              let registry = case previous {
                Some(old) -> retire(registry, old, None)
                None -> registry
              }
              process.send(reply, Ok(entry.ref))
              actor.continue(
                Registry(..registry, active: [entry, ..registry.active]),
              )
            }
          }
      }
    }
    Retire(id, reply) ->
      case find_active(registry, id) {
        Ok(entry) -> actor.continue(retire(registry, entry, Some(reply)))
        Error(Nil) -> {
          respond(reply, Error(HandlerNotFound))
          actor.continue(registry)
        }
      }
    Drained(id) -> {
      case dict.get(registry.retiring, id) {
        Ok(Retiring(_, Some(waiter))) -> respond(waiter, Ok(Nil))
        Ok(Retiring(_, None)) | Error(Nil) -> Nil
      }
      actor.continue(
        Registry(..registry, retiring: dict.delete(registry.retiring, id)),
      )
    }
    Which(reply) -> {
      process.send(
        reply,
        list.reverse(list.map(registry.active, fn(entry) { entry.ref.id })),
      )
      actor.continue(registry)
    }
    Notify(event) -> {
      dispatch(registry.active, event, None)
      actor.continue(registry)
    }
    Sync(event, caller, deadline, reply) ->
      actor.continue(admit(registry, event, caller, deadline, reply))
    Ack(key, id) ->
      actor.continue(
        Registry(
          ..registry,
          pending: account(registry.pending, key, id, Acknowledged),
        ),
      )
    Expire(key) ->
      actor.continue(
        Registry(..registry, pending: dict.delete(registry.pending, key)),
      )
    Exited(process.ExitMessage(pid, reason)) ->
      case Some(pid) == registry.parent {
        True -> {
          // Propagate parent shutdown to workers even if a callback is
          // blocked, then exit with the parent's reason so a supervisor
          // sees `shutdown` rather than an unexpected `normal`.
          list.each(all_entries(registry), fn(entry) {
            process.kill(entry.ref.id.pid)
          })
          exit_with(reason)
        }
        False -> actor.continue(worker_exited(registry, HandlerId(pid), reason))
      }
    Shutdown(reply) -> {
      list.each(registry.active, fn(entry) {
        process.send(entry.ref.inbox, Drain)
      })
      dict.each(registry.pending, fn(key, pending) {
        respond(
          key,
          Unconfirmed(list.append(set.to_list(pending.remaining), pending.lost)),
        )
      })
      respond(reply, Nil)
      actor.stop()
    }
  }
}

fn find_active(
  registry: Registry(event),
  id: HandlerId,
) -> Result(Entry(event), Nil) {
  list.find(registry.active, fn(entry) { entry.ref.id == id })
}

fn admit(
  registry: Registry(event),
  event: event,
  caller: Pid,
  deadline: Int,
  reply: Waiter(SyncResult),
) -> Registry(event) {
  let now = now_ms()
  let registry =
    Registry(
      ..registry,
      pending: dict.filter(registry.pending, fn(_, pending) {
        pending.deadline > now
      }),
    )
  let ids = set.from_list(list.map(registry.active, fn(entry) { entry.ref.id }))
  let saturated = dict.size(registry.pending) >= registry.max_in_flight_sync
  let reentrant = set.contains(ids, HandlerId(caller))
  case reentrant, saturated, registry.active {
    True, _, _ -> {
      respond(reply, SyncReentrant)
      registry
    }
    False, True, _ -> {
      respond(reply, SyncBusy)
      registry
    }
    False, False, [] -> {
      respond(reply, Confirmed)
      registry
    }
    False, False, [_, ..] if deadline <= now -> {
      dispatch(registry.active, event, None)
      respond(reply, SyncTimeout)
      registry
    }
    False, False, [_, ..] -> {
      let timer =
        process.send_after(registry.inbox, deadline - now, Expire(reply))
      dispatch(registry.active, event, Some(reply))
      Registry(
        ..registry,
        pending: dict.insert(
          registry.pending,
          reply,
          Pending(remaining: ids, lost: [], expiry: timer, deadline: deadline),
        ),
      )
    }
  }
}

fn worker_exited(
  registry: Registry(event),
  id: HandlerId,
  reason: ExitReason,
) -> Registry(event) {
  case dict.get(registry.retiring, id) {
    Ok(Retiring(_, Some(waiter))) -> respond(waiter, Error(DrainInterrupted))
    Ok(Retiring(_, None)) | Error(Nil) -> Nil
  }
  case list.find(all_entries(registry), fn(entry) { entry.ref.id == id }) {
    Ok(Entry(_, Some(observer))) if reason != process.Normal ->
      notify_observer(observer, HandlerDown(id, reason))
    Ok(Entry(_, _)) | Error(Nil) -> Nil
  }
  let pending =
    list.fold(dict.keys(registry.pending), registry.pending, fn(pending, key) {
      account(pending, key, id, Lost)
    })
  Registry(
    ..registry,
    active: list.filter(registry.active, fn(entry) { entry.ref.id != id }),
    retiring: dict.delete(registry.retiring, id),
    pending: pending,
  )
}

fn all_entries(registry: Registry(event)) -> List(Entry(event)) {
  list.append(
    registry.active,
    list.map(dict.values(registry.retiring), fn(retiring) { retiring.entry }),
  )
}

fn dispatch(
  entries: List(Entry(event)),
  event: event,
  delivery: Option(Waiter(SyncResult)),
) -> Nil {
  list.each(entries, fn(entry: Entry(event)) {
    process.send(entry.ref.inbox, Deliver(event, delivery))
  })
}

fn retire(
  registry: Registry(event),
  entry: Entry(event),
  reply: Option(DrainWaiter),
) -> Registry(event) {
  process.send(entry.ref.inbox, Drain)
  Registry(
    ..registry,
    active: list.filter(registry.active, fn(other) {
      other.ref.id != entry.ref.id
    }),
    retiring: dict.insert(
      registry.retiring,
      entry.ref.id,
      Retiring(entry, reply),
    ),
  )
}

fn account(
  all: Dict(Waiter(SyncResult), Pending),
  key: Waiter(SyncResult),
  id: HandlerId,
  receipt: Receipt,
) -> Dict(Waiter(SyncResult), Pending) {
  case dict.get(all, key) {
    Error(Nil) -> all
    Ok(pending) ->
      case set.contains(pending.remaining, id) {
        False -> all
        True -> {
          let remaining = set.delete(pending.remaining, id)
          let lost = case receipt {
            Lost -> [id, ..pending.lost]
            Acknowledged -> pending.lost
          }
          case set.is_empty(remaining) {
            True -> {
              let _ = process.cancel_timer(pending.expiry)
              respond(key, case lost {
                [] -> Confirmed
                [_, ..] -> Unconfirmed(lost)
              })
              dict.delete(all, key)
            }
            False ->
              dict.insert(
                all,
                key,
                Pending(..pending, remaining: remaining, lost: lost),
              )
          }
        }
      }
  }
}

/// Describe a handler by its initial state and event callback. Each
/// `add_handler` call starts a fresh instance from `initial_state`.
///
/// ## Example
///
/// ```gleam
/// event_manager.new_handler(0, fn(_event, seen) {
///   event_manager.Continue(seen + 1)
/// })
/// ```
///
pub fn new_handler(
  initial_state: state,
  handler: fn(event, state) -> EventStep(state),
) -> Handler(state, event) {
  Handler(initial: initial_state, handle: handler, cleanup: fn(_) { Nil })
}

/// Run `cleanup` with the final state when the instance returns `Remove`,
/// is removed, or is replaced. It does not run if the worker is killed.
///
/// ## Example
///
/// ```gleam
/// event_manager.new_handler(file, write_line)
/// |> event_manager.on_terminate(fn(file) { close(file) })
/// ```
///
pub fn on_terminate(
  handler: Handler(state, event),
  cleanup: fn(state) -> Nil,
) -> Handler(state, event) {
  Handler(..handler, cleanup: cleanup)
}

fn spawn_worker(
  manager: Manager(event),
  handler: Handler(state, event),
  on_down: Option(Subject(HandlerDown)),
) -> Result(Entry(event), StartError) {
  use started <- result.map(
    actor.new(handler.initial)
    |> actor.on_message(fn(state, message) {
      case message {
        Deliver(event, delivery) -> {
          let next = handler.handle(event, state)
          case delivery {
            Some(key) ->
              process.send(manager.subject, Ack(key, HandlerId(process.self())))
            None -> Nil
          }
          case next {
            Continue(state) -> actor.continue(state)
            Remove -> {
              handler.cleanup(state)
              actor.stop()
            }
          }
        }
        Drain -> {
          handler.cleanup(state)
          process.send(manager.subject, Drained(HandlerId(process.self())))
          actor.stop()
        }
      }
    })
    |> actor.start,
  )
  Entry(HandlerRef(HandlerId(started.pid), started.data), on_down)
}

/// Register a new worker linked to the manager. The registrar has no link to
/// the worker. `on_down` reports abnormal exits, including cleanup failures.
///
/// ## Example
///
/// ```gleam
/// let assert Ok(ref) =
///   event_manager.add_handler(manager, handler, on_down: Some(observer))
/// ```
///
pub fn add_handler(
  manager: Manager(event),
  handler: Handler(state, event),
  on_down on_down: Option(Subject(HandlerDown)),
) -> Result(HandlerRef(event), AddError) {
  install(manager, None, handler, on_down)
}

/// Replace membership atomically with a fresh instance and independent initial
/// state. Previously accepted events still drain on the old instance.
///
/// ## Example
///
/// ```gleam
/// let assert Ok(new_ref) =
///   event_manager.replace_handler(manager, old_ref, handler, on_down: None)
/// ```
///
pub fn replace_handler(
  manager: Manager(event),
  old: HandlerRef(event),
  next: Handler(state, event),
  on_down on_down: Option(Subject(HandlerDown)),
) -> Result(HandlerRef(event), AddError) {
  install(manager, Some(old.id), next, on_down)
}

fn install(
  manager: Manager(event),
  replacing: Option(HandlerId),
  handler: Handler(state, event),
  on_down: Option(Subject(HandlerDown)),
) -> Result(HandlerRef(event), AddError) {
  let reply = process.new_subject()
  let monitor = process.monitor(manager.pid)
  process.send(
    manager.subject,
    Install(replacing, fn() { spawn_worker(manager, handler, on_down) }, reply),
  )
  let outcome =
    process.new_selector()
    |> process.select(reply)
    |> process.select_specific_monitor(monitor, fn(_) { Error(AddManagerDown) })
    |> process.selector_receive_forever
  process.demonitor_process(monitor)
  outcome
}

/// Removes membership on acceptance. Success also proves that queued events
/// and cleanup completed. A timeout does not roll back removal.
///
/// ## Example
///
/// ```gleam
/// let assert Ok(Nil) = event_manager.remove_handler(manager, ref, 1000)
/// ```
///
pub fn remove_handler(
  manager: Manager(event),
  ref: HandlerRef(event),
  timeout: Int,
) -> Result(Nil, RemoveError) {
  let outcome =
    request(manager.pid, timeout, fn(reply, _) {
      process.send(manager.subject, Retire(ref.id, reply))
    })
  case outcome {
    Ok(removal) -> removal
    Error(WaitDown) -> Error(RemoveManagerDown)
    Error(WaitTimeout) -> Error(RemoveTimedOut)
  }
}

/// Snapshot in registration order; Error if the manager has exited.
///
/// ## Example
///
/// ```gleam
/// let assert Ok([first, second]) = event_manager.which_handlers(manager)
/// ```
///
pub fn which_handlers(manager: Manager(event)) -> Result(List(HandlerId), Nil) {
  let reply = process.new_subject()
  let monitor = process.monitor(manager.pid)
  process.send(manager.subject, Which(reply))
  let outcome =
    process.new_selector()
    |> process.select_map(reply, Ok)
    |> process.select_specific_monitor(monitor, fn(_) { Error(Nil) })
    |> process.selector_receive_forever
  process.demonitor_process(monitor)
  outcome
}

/// The manager's process identifier, for monitoring or linking.
///
/// ## Example
///
/// ```gleam
/// process.monitor(event_manager.manager_pid(manager))
/// ```
///
pub fn manager_pid(manager: Manager(event)) -> Pid {
  manager.pid
}

/// Returns after sending to the manager; does not wait for acceptance.
///
/// ## Example
///
/// ```gleam
/// event_manager.notify(manager, UserSignedIn(id))
/// ```
///
pub fn notify(manager: Manager(event), event: event) -> Nil {
  process.send(manager.subject, Notify(event))
}

/// Wait for the acceptance snapshot to acknowledge or for the caller's wait
/// to expire. An enrolled callback cannot synchronously wait on itself
/// (`SyncReentrant`). A dead manager yields `SyncManagerDown`, never
/// `SyncTimeout`.
///
/// ## Example
///
/// ```gleam
/// case event_manager.sync_notify(manager, Flush, 1000) {
///   event_manager.Confirmed -> Nil
///   other -> log_degraded(other)
/// }
/// ```
///
pub fn sync_notify(
  manager: Manager(event),
  event: event,
  timeout: Int,
) -> SyncResult {
  let outcome =
    request(manager.pid, timeout, fn(reply, deadline) {
      process.send(
        manager.subject,
        Sync(event, process.self(), deadline, reply),
      )
    })
  case outcome {
    Ok(result) -> result
    Error(WaitTimeout) -> SyncTimeout
    Error(WaitDown) -> SyncManagerDown
  }
}

/// Bypass the manager. There is no order guarantee relative to broadcasts
/// sent concurrently by another process.
///
/// ## Example
///
/// ```gleam
/// event_manager.send_to(ref, Reload)
/// ```
///
pub fn send_to(ref: HandlerRef(event), event: event) -> Nil {
  process.send(ref.inbox, Deliver(event, None))
}

/// Signal all current workers to drain. This waits for manager acceptance,
/// not completion of cleanup on each worker.
///
/// ## Example
///
/// ```gleam
/// let assert Ok(Nil) = event_manager.stop(manager, 1000)
/// ```
///
pub fn stop(manager: Manager(event), timeout: Int) -> Result(Nil, StopError) {
  request(manager.pid, timeout, fn(reply, _) {
    process.send(manager.subject, Shutdown(reply))
  })
  |> result.map_error(fn(error) {
    case error {
      WaitDown -> AlreadyStopped
      WaitTimeout -> StopTimedOut
    }
  })
}
