//// Broadcast events to independently scheduled handler actors. Membership is
//// sampled when the manager processes a publication. Each recipient sees that
//// manager's broadcasts in FIFO order; callbacks on different actors can run
//// in either order. A confirmation observes processing, not durable storage.

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
  Continue(state)
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

/// Timeout does not cancel dispatch. Busy means no dispatch took place.
pub type SyncResult {
  Confirmed
  Unconfirmed(handlers: List(HandlerId))
  SyncTimeout
  SyncBusy
}

pub type StartError =
  actor.StartError

pub type AddError {
  ManagerDown
  HandlerStartFailed(StartError)
  StaleRef
}

pub type RemoveError {
  HandlerNotFound
  RemoveTimedOut
  DrainInterrupted
}

pub opaque type StartOptions {
  StartOptions(init_timeout: Int, max: Int)
}

pub fn new_start_options() -> StartOptions {
  StartOptions(5000, 64)
}

pub fn with_init_timeout(options: StartOptions, timeout: Int) -> StartOptions {
  StartOptions(..options, init_timeout: int.max(timeout, 0))
}

/// Bounds confirmation bookkeeping, not worker mailboxes. Zero rejects all
/// synchronous publications.
pub fn with_max_in_flight_sync(
  options: StartOptions,
  max: Int,
) -> StartOptions {
  StartOptions(..options, max: int.max(max, 0))
}

pub opaque type Manager(event) {
  Manager(pid: Pid, subject: Subject(Cmd(event)))
}

type Envelope(event) {
  Deliver(event, Option(Subject(SyncResult)))
  Drain(Option(Subject(Result(Nil, RemoveError))))
}

type Entry(event) {
  Entry(ref: HandlerRef(event), on_down: Option(Subject(HandlerDown)))
}

type Pending {
  Pending(
    remaining: Set(HandlerId),
    lost: List(HandlerId),
    expiry: process.Timer,
  )
}

type Cmd(event) {
  Install(
    Option(HandlerId),
    fn() -> Result(Entry(event), StartError),
    Subject(Result(HandlerRef(event), AddError)),
  )
  Retire(HandlerId, Subject(Result(Nil, RemoveError)))
  Which(Subject(List(HandlerId)))
  Notify(event)
  Sync(event, Pid, Int, Subject(SyncResult))
  Ack(Subject(SyncResult), HandlerId)
  Expire(Subject(SyncResult))
  Exited(process.ExitMessage)
  Shutdown(Subject(Nil))
}

type Registry(event) {
  Registry(
    inbox: Subject(Cmd(event)),
    parent: Option(Pid),
    active: List(Entry(event)),
    retiring: Dict(HandlerId, Entry(event)),
    pending: Dict(Subject(SyncResult), Pending),
    max: Int,
  )
}

pub fn start_link(options: StartOptions) -> Result(Manager(event), StartError) {
  launch(options, True)
}

pub fn start(options: StartOptions) -> Result(Manager(event), StartError) {
  launch(options, False)
}

/// Starts unlinked and monitors the returned pid; death before the monitor is
/// installed is observed as a down notification for a missing process.
pub fn start_monitor(
  options: StartOptions,
) -> Result(#(Manager(event), process.Monitor), StartError) {
  use manager <- result.map(start(options))
  #(manager, process.monitor(manager.pid))
}

fn launch(options: StartOptions, linked: Bool) {
  let caller = process.self()
  use started <- result.map(
    actor.new_with_initialiser(options.init_timeout, fn(inbox) {
      process.trap_exits(True)
      let parent = case linked {
        True -> Some(caller)
        False -> {
          process.unlink(caller)
          None
        }
      }
      Ok(
        actor.initialised(Registry(
          inbox,
          parent,
          [],
          dict.new(),
          dict.new(),
          options.max,
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

fn handle(s: Registry(event), command: Cmd(event)) {
  case command {
    Install(old, spawn, reply) -> {
      let previous =
        option.then(old, fn(id) {
          list.find(s.active, fn(e) { e.ref.id == id }) |> option.from_result
        })
      case old, previous {
        Some(_), None -> {
          process.send(reply, Error(StaleRef))
          actor.continue(s)
        }
        _, _ ->
          case spawn() {
            Error(e) -> {
              process.send(reply, Error(HandlerStartFailed(e)))
              actor.continue(s)
            }
            Ok(entry) -> {
              let s = case previous {
                Some(e) -> retire(s, e, None)
                None -> s
              }
              process.send(reply, Ok(entry.ref))
              actor.continue(Registry(..s, active: [entry, ..s.active]))
            }
          }
      }
    }
    Retire(id, reply) ->
      case list.find(s.active, fn(e) { e.ref.id == id }) {
        Ok(e) -> actor.continue(retire(s, e, Some(reply)))
        Error(_) -> {
          process.send(reply, Error(HandlerNotFound))
          actor.continue(s)
        }
      }
    Which(reply) -> {
      process.send(reply, list.reverse(list.map(s.active, fn(e) { e.ref.id })))
      actor.continue(s)
    }
    Notify(event) -> {
      dispatch(s.active, event, None)
      actor.continue(s)
    }
    Sync(event, caller, timeout, reply) -> {
      let ids = set.from_list(list.map(s.active, fn(e) { e.ref.id }))
      case
        dict.size(s.pending) >= s.max || set.contains(ids, HandlerId(caller)),
        s.active
      {
        True, _ -> {
          process.send(reply, SyncBusy)
          actor.continue(s)
        }
        False, [] -> {
          process.send(reply, Confirmed)
          actor.continue(s)
        }
        False, _ -> {
          let timer = process.send_after(s.inbox, timeout, Expire(reply))
          dispatch(s.active, event, Some(reply))
          actor.continue(
            Registry(
              ..s,
              pending: dict.insert(s.pending, reply, Pending(ids, [], timer)),
            ),
          )
        }
      }
    }
    Ack(key, id) ->
      actor.continue(Registry(..s, pending: account(s.pending, key, id, False)))
    Expire(key) ->
      actor.continue(Registry(..s, pending: dict.delete(s.pending, key)))
    Exited(process.ExitMessage(pid, reason)) ->
      case Some(pid) == s.parent {
        True -> {
          // Propagate parent shutdown to workers even if a callback is blocked.
          list.each(list.append(s.active, dict.values(s.retiring)), fn(e) {
            process.kill(e.ref.id.pid)
          })
          actor.stop()
        }
        False -> {
          let id = HandlerId(pid)
          let entries = list.append(s.active, dict.values(s.retiring))
          case list.find(entries, fn(e) { e.ref.id == id }), reason {
            Ok(Entry(_, Some(down))), r if r != process.Normal ->
              notify_observer(down, HandlerDown(id, r))
            _, _ -> Nil
          }
          let pending =
            list.fold(dict.keys(s.pending), s.pending, fn(p, k) {
              account(p, k, id, True)
            })
          actor.continue(
            Registry(
              ..s,
              active: list.filter(s.active, fn(e) { e.ref.id != id }),
              retiring: dict.delete(s.retiring, id),
              pending: pending,
            ),
          )
        }
      }
    Shutdown(reply) -> {
      list.each(s.active, fn(e) { process.send(e.ref.inbox, Drain(None)) })
      dict.each(s.pending, fn(k, p) {
        process.send(
          k,
          Unconfirmed(list.append(set.to_list(p.remaining), p.lost)),
        )
      })
      process.send(reply, Nil)
      actor.stop()
    }
  }
}

fn dispatch(entries, event, delivery) {
  list.each(entries, fn(entry: Entry(event)) {
    process.send(entry.ref.inbox, Deliver(event, delivery))
  })
}

fn retire(s: Registry(event), e: Entry(event), reply) {
  process.send(e.ref.inbox, Drain(reply))
  Registry(
    ..s,
    active: list.filter(s.active, fn(other) { other.ref.id != e.ref.id }),
    retiring: dict.insert(s.retiring, e.ref.id, e),
  )
}

fn account(all: Dict(Subject(SyncResult), Pending), key, id, died) {
  case dict.get(all, key) {
    Error(_) -> all
    Ok(p) ->
      case set.contains(p.remaining, id) {
        False -> all
        True -> {
          let remaining = set.delete(p.remaining, id)
          let lost = case died {
            True -> [id, ..p.lost]
            False -> p.lost
          }
          case set.size(remaining) {
            0 -> {
              let _ = process.cancel_timer(p.expiry)
              process.send(key, case lost {
                [] -> Confirmed
                _ -> Unconfirmed(lost)
              })
              dict.delete(all, key)
            }
            _ ->
              dict.insert(
                all,
                key,
                Pending(..p, remaining: remaining, lost: lost),
              )
          }
        }
      }
  }
}

pub fn new_handler(
  initial_state: state,
  handler: fn(event, state) -> EventStep(state),
) -> Handler(state, event) {
  Handler(initial_state, handler, fn(_) { Nil })
}

pub fn on_terminate(
  handler: Handler(state, event),
  cleanup: fn(state) -> Nil,
) -> Handler(state, event) {
  Handler(..handler, cleanup: cleanup)
}

fn spawn_worker(manager: Manager(event), handler: Handler(state, event), down) {
  use started <- result.map(
    actor.new(handler.initial)
    |> actor.on_message(fn(state, msg) {
      case msg {
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
        Drain(reply) -> {
          handler.cleanup(state)
          case reply {
            Some(r) -> process.send(r, Ok(Nil))
            None -> Nil
          }
          actor.stop()
        }
      }
    })
    |> actor.start,
  )
  Entry(HandlerRef(HandlerId(started.pid), started.data), down)
}

/// Register a new worker linked to the manager. The registrar has no link to
/// the worker. `on_down` reports abnormal exits, including cleanup failures.
pub fn add_handler(
  manager: Manager(event),
  handler: Handler(state, event),
  on_down down: Option(Subject(HandlerDown)),
) -> Result(HandlerRef(event), AddError) {
  install(manager, None, handler, down)
}

/// Replace membership atomically with a fresh instance and independent initial
/// state. Previously accepted events still drain on the old instance.
pub fn replace_handler(
  manager: Manager(event),
  old: HandlerRef(event),
  next: Handler(state, event),
  on_down down: Option(Subject(HandlerDown)),
) -> Result(HandlerRef(event), AddError) {
  install(manager, Some(old.id), next, down)
}

fn install(manager: Manager(event), old, handler, down) {
  let reply = process.new_subject()
  let monitor = process.monitor(manager.pid)
  process.send(
    manager.subject,
    Install(old, fn() { spawn_worker(manager, handler, down) }, reply),
  )
  let outcome =
    process.new_selector()
    |> process.select(reply)
    |> process.select_specific_monitor(monitor, fn(_) { Error(ManagerDown) })
    |> process.selector_receive_forever
  process.demonitor_process(monitor)
  outcome
}

/// Removes membership on acceptance. Success also proves that queued events
/// and cleanup completed. A timeout does not roll back removal.
pub fn remove_handler(
  manager: Manager(event),
  ref: HandlerRef(event),
  timeout: Int,
) -> Result(Nil, RemoveError) {
  let reply = process.new_subject()
  process.send(manager.subject, Retire(ref.id, reply))
  case process.receive(reply, int.max(timeout, 0)) {
    Ok(r) -> r
    Error(_) -> Error(RemoveTimedOut)
  }
}

/// Snapshot in registration order; Error if the manager has exited.
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

pub fn manager_pid(manager: Manager(event)) -> Pid {
  manager.pid
}

/// Returns after sending to the manager; does not wait for acceptance.
pub fn notify(manager: Manager(event), event: event) -> Nil {
  process.send(manager.subject, Notify(event))
}

/// Wait for the acceptance snapshot to acknowledge or for the caller's wait
/// to expire. An enrolled callback cannot synchronously wait on itself.
pub fn sync_notify(
  manager: Manager(event),
  event: event,
  timeout: Int,
) -> SyncResult {
  let reply = process.new_subject()
  let timeout = int.max(timeout, 0)
  process.send(manager.subject, Sync(event, process.self(), timeout, reply))
  process.receive(reply, timeout) |> result.unwrap(SyncTimeout)
}

/// Bypass the manager. There is no order guarantee relative to broadcasts
/// sent concurrently by another process.
pub fn send_to(ref: HandlerRef(event), event: event) -> Nil {
  process.send(ref.inbox, Deliver(event, None))
}

/// Signal all current workers to drain. This waits for manager acceptance,
/// not completion of cleanup on each worker.
pub fn stop(manager: Manager(event), timeout: Int) -> Nil {
  let reply = process.new_subject()
  process.send(manager.subject, Shutdown(reply))
  let _ = process.receive(reply, int.max(timeout, 0))
  Nil
}
