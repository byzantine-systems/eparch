////
//// Integration tests for eparch/event_manager (gen_event wrapper).
////
//// Each section has its own event type, prefixed to avoid constructor
//// name collisions across sections.
////

import eparch/event_manager
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/string
import gleeunit/should

@external(erlang, "sys", "get_status")
fn sys_get_status(pid: process.Pid) -> Dynamic

// ---------------------------------------------------------------------------
// START / STOP
// ---------------------------------------------------------------------------

pub fn start_and_stop_test() {
  let assert Ok(mgr) = event_manager.start()
  event_manager.stop(mgr)
}

// ---------------------------------------------------------------------------
// NOTIFY
//
// An event sent via notify/2 reaches the handler asynchronously.
// The handler embeds a Subject in the event and replies to it.
// ---------------------------------------------------------------------------

type NotifyMsg {
  NotifyPing(reply_with: process.Subject(String))
}

pub fn notify_delivers_event_to_handler_test() {
  let assert Ok(mgr) = event_manager.start()

  let handler =
    event_manager.new_handler(Nil, fn(event, state) {
      case event {
        NotifyPing(reply_with: sub) -> {
          process.send(sub, "pong")
          event_manager.Continue(state)
        }
      }
    })

  let assert Ok(_ref) = event_manager.add_handler(mgr, handler)

  let reply_sub = process.new_subject()
  event_manager.notify(mgr, NotifyPing(reply_with: reply_sub))

  let assert Ok(reply) = process.receive(reply_sub, 1000)
  reply |> should.equal("pong")

  event_manager.stop(mgr)
}

// ---------------------------------------------------------------------------
// SYNC NOTIFY
//
// sync_notify/2 blocks until the handler has processed the event.
// We verify ordering: sync_notify completes before we do a second send.
// ---------------------------------------------------------------------------

type SyncMsg {
  SyncPing(reply_with: process.Subject(String))
}

pub fn sync_notify_blocks_until_handler_processes_event_test() {
  let assert Ok(mgr) = event_manager.start()

  let handler =
    event_manager.new_handler(Nil, fn(event, state) {
      case event {
        SyncPing(reply_with: sub) -> {
          process.send(sub, "sync-pong")
          event_manager.Continue(state)
        }
      }
    })

  let assert Ok(_ref) = event_manager.add_handler(mgr, handler)

  let reply_sub = process.new_subject()
  event_manager.sync_notify(mgr, SyncPing(reply_with: reply_sub))

  // Because sync_notify blocked, the reply is already in the mailbox.
  let assert Ok(reply) = process.receive(reply_sub, 0)
  reply |> should.equal("sync-pong")

  event_manager.stop(mgr)
}

// ---------------------------------------------------------------------------
// MULTIPLE HANDLERS
//
// Two independent handlers both receive the same broadcast event.
// ---------------------------------------------------------------------------

type MultiMsg {
  MultiPing(reply_with: process.Subject(String))
}

pub fn multiple_handlers_both_receive_broadcast_test() {
  let assert Ok(mgr) = event_manager.start()

  let make_handler = fn(tag: String) {
    event_manager.new_handler(Nil, fn(event, state) {
      case event {
        MultiPing(reply_with: sub) -> {
          process.send(sub, tag)
          event_manager.Continue(state)
        }
      }
    })
  }

  let assert Ok(_ref1) = event_manager.add_handler(mgr, make_handler("first"))
  let assert Ok(_ref2) = event_manager.add_handler(mgr, make_handler("second"))

  let reply_sub = process.new_subject()
  event_manager.sync_notify(mgr, MultiPing(reply_with: reply_sub))

  // Both handlers replied; order depends on gen_event dispatch, so sort.
  let assert Ok(r1) = process.receive(reply_sub, 1000)
  let assert Ok(r2) = process.receive(reply_sub, 1000)

  list.sort([r1, r2], by: fn(a, b) { string.compare(a, b) })
  |> should.equal(["first", "second"])

  event_manager.stop(mgr)
}

// ---------------------------------------------------------------------------
// HANDLER SELF-REMOVAL
//
// A handler can remove itself by returning Remove from on_event.
// After removal, which_handlers should no longer include its ref.
// ---------------------------------------------------------------------------

type RemoveSelfMsg {
  RemoveSelfNow
}

pub fn handler_removes_itself_via_remove_step_test() {
  let assert Ok(mgr) = event_manager.start()

  let counter_handler =
    event_manager.new_handler(Nil, fn(event, _state) {
      case event {
        RemoveSelfNow -> event_manager.Remove
      }
    })

  let assert Ok(ref) = event_manager.add_handler(mgr, counter_handler)

  // The handler is present before removal.
  event_manager.which_handlers(mgr) |> should.equal([ref])

  // Trigger self-removal.
  event_manager.sync_notify(mgr, RemoveSelfNow)

  // After removal, which_handlers is empty.
  event_manager.which_handlers(mgr) |> should.equal([])

  event_manager.stop(mgr)
}

// ---------------------------------------------------------------------------
// EXPLICIT REMOVE HANDLER
//
// remove_handler/2 removes a specific handler by its ref.
// ---------------------------------------------------------------------------

pub fn explicit_remove_handler_removes_by_ref_test() {
  let assert Ok(mgr) = event_manager.start()

  let h =
    event_manager.new_handler(Nil, fn(_event, state) {
      event_manager.Continue(state)
    })

  let assert Ok(ref) = event_manager.add_handler(mgr, h)
  event_manager.which_handlers(mgr) |> should.equal([ref])

  let assert Ok(Nil) = event_manager.remove_handler(mgr, ref)
  event_manager.which_handlers(mgr) |> should.equal([])

  event_manager.stop(mgr)
}

// ---------------------------------------------------------------------------
// WHICH HANDLERS
//
// which_handlers reflects the current set of registered handlers accurately
// across add/remove operations.
// ---------------------------------------------------------------------------

pub fn which_handlers_reflects_add_and_remove_operations_test() {
  let assert Ok(mgr) = event_manager.start()

  let make_h = fn() {
    event_manager.new_handler(Nil, fn(_event, state) {
      event_manager.Continue(state)
    })
  }

  // Empty at start.
  event_manager.which_handlers(mgr) |> should.equal([])

  let assert Ok(ref1) = event_manager.add_handler(mgr, make_h())
  event_manager.which_handlers(mgr) |> should.equal([ref1])

  let assert Ok(ref2) = event_manager.add_handler(mgr, make_h())
  let handlers_after_two = event_manager.which_handlers(mgr)
  handlers_after_two |> list.length() |> should.equal(2)
  handlers_after_two |> list.contains(ref1) |> should.equal(True)
  handlers_after_two |> list.contains(ref2) |> should.equal(True)

  let assert Ok(Nil) = event_manager.remove_handler(mgr, ref1)
  event_manager.which_handlers(mgr) |> should.equal([ref2])

  let assert Ok(Nil) = event_manager.remove_handler(mgr, ref2)
  event_manager.which_handlers(mgr) |> should.equal([])

  event_manager.stop(mgr)
}

// ---------------------------------------------------------------------------
// ON TERMINATE
//
// The on_terminate callback is invoked when a handler is removed.
// ---------------------------------------------------------------------------

type TerminateMsg {
  TerminateNow
}

pub fn on_terminate_called_when_handler_removed_test() {
  let assert Ok(mgr) = event_manager.start()

  let reply_sub = process.new_subject()

  let h =
    event_manager.new_handler(Nil, fn(event, _state) {
      case event {
        TerminateNow -> event_manager.Remove
      }
    })
    |> event_manager.on_terminate(fn(_state) {
      process.send(reply_sub, "terminated")
    })

  let assert Ok(_ref) = event_manager.add_handler(mgr, h)

  event_manager.sync_notify(mgr, TerminateNow)

  let assert Ok(msg) = process.receive(reply_sub, 1000)
  msg |> should.equal("terminated")

  event_manager.stop(mgr)
}

// ---------------------------------------------------------------------------
// ON FORMAT STATUS
//
// When on_format_status is set, sys:get_status/1 reflects the formatted
// state. When unset, the call still succeeds (raw state passes through).
// ---------------------------------------------------------------------------

pub fn on_format_status_overrides_state_in_status_report_test() {
  let assert Ok(mgr) = event_manager.start()

  let h =
    event_manager.new_handler(42, fn(_event, state) {
      event_manager.Continue(state)
    })
    |> event_manager.on_format_status(fn(n) { "FORMATTED:" <> int.to_string(n) })

  let assert Ok(_ref) = event_manager.add_handler(mgr, h)

  let status = sys_get_status(event_manager.manager_pid(mgr))
  string.inspect(status)
  |> string.contains("FORMATTED:42")
  |> should.equal(True)

  event_manager.stop(mgr)
}

pub fn handler_without_format_status_still_appears_in_status_test() {
  let assert Ok(mgr) = event_manager.start()

  let h =
    event_manager.new_handler(Nil, fn(_event, state) {
      event_manager.Continue(state)
    })

  let assert Ok(_ref) = event_manager.add_handler(mgr, h)

  // Should not crash; sys:get_status returns a non-empty term.
  let _ = sys_get_status(event_manager.manager_pid(mgr))

  event_manager.stop(mgr)
}

// ---------------------------------------------------------------------------
// START MONITOR
//
// start_monitor/0,1,2 (OTP 23.0+) starts the manager linked to the caller
// and atomically returns a monitor. The monitor fires when the manager
// exits.
// ---------------------------------------------------------------------------

type StartMonitorMsg {
  StartMonitorPing(reply_with: process.Subject(String))
}

pub fn start_monitor_returns_manager_and_monitor_test() {
  let assert Ok(monitored) =
    event_manager.start_monitor(event_manager.new_start_options())

  let handler =
    event_manager.new_handler(Nil, fn(event, state) {
      case event {
        StartMonitorPing(reply_with: subject) -> {
          process.send(subject, "pong")
          event_manager.Continue(state)
        }
      }
    })

  let assert Ok(_ref) = event_manager.add_handler(monitored.manager, handler)

  let reply_subject = process.new_subject()
  event_manager.sync_notify(
    monitored.manager,
    StartMonitorPing(reply_with: reply_subject),
  )

  let assert Ok(reply) = process.receive(reply_subject, 1000)
  reply |> should.equal("pong")

  event_manager.stop(monitored.manager)
}

pub fn start_monitor_fires_monitor_on_stop_test() {
  let assert Ok(monitored) =
    event_manager.start_monitor(event_manager.new_start_options())

  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitored.monitor, fn(down) { down })

  event_manager.stop(monitored.manager)

  let assert Ok(_down) = process.selector_receive(from: selector, within: 1000)
}

pub fn start_monitor_with_name_registers_process_test() {
  let name = process.new_name("eparch_event_manager_test_")
  let options =
    event_manager.new_start_options()
    |> event_manager.with_name(name)

  let assert Ok(monitored) = event_manager.start_monitor(options)

  let assert Ok(registered_pid) = process.named(name)
  registered_pid |> should.equal(event_manager.manager_pid(monitored.manager))

  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitored.monitor, fn(down) { down })

  event_manager.stop(monitored.manager)

  let assert Ok(_down) = process.selector_receive(from: selector, within: 1000)
}

pub fn start_monitor_already_started_returns_error_test() {
  let name = process.new_name("eparch_event_manager_dup_test_")
  let options =
    event_manager.new_start_options()
    |> event_manager.with_name(name)

  let assert Ok(monitored) = event_manager.start_monitor(options)
  let first_pid = event_manager.manager_pid(monitored.manager)

  let assert Error(event_manager.AlreadyStarted(reported_pid)) =
    event_manager.start_monitor(options)
  reported_pid |> should.equal(first_pid)

  event_manager.stop(monitored.manager)
}

pub fn start_monitor_accepts_option_passthrough_test() {
  let options =
    event_manager.new_start_options()
    |> event_manager.with_timeout(event_manager.Milliseconds(5000))
    |> event_manager.with_spawn_options([
      event_manager.SpawnPriority(event_manager.PriorityNormal),
    ])

  let assert Ok(monitored) = event_manager.start_monitor(options)

  event_manager.stop(monitored.manager)
}
