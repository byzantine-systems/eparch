////
//// Integration tests for the terminal-logger broadcast example.
////
//// These tests spawn a real actor manager and exercise it through
//// the public API. Because the bundled `terminal_logger` handler prints
//// to stdout (which is hard to capture in a unit test), most tests
//// install an in-test **collector** handler that forwards each received
//// event to a `process.Subject`. That handler shares the manager with
//// the production handlers, demonstrating the fan-out behaviour of
//// the bus.
////

import eparch/event_manager
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleeunit/should
import simplifile
import terminal_logger.{type ErrorEvent, Reported}

// Helpers

/// Install a handler that forwards every received event to `subject`.
/// Returns its `HandlerRef` so the test can remove it later if needed.
fn install_collector(
  manager: event_manager.Manager(ErrorEvent),
  subject: process.Subject(ErrorEvent),
) -> event_manager.HandlerRef(ErrorEvent) {
  let handler =
    event_manager.new_handler(Nil, fn(event, state) {
      process.send(subject, event)
      event_manager.Continue(state)
    })

  let assert Ok(ref) =
    event_manager.add_handler(manager, handler, on_down: None)
  ref
}

/// Pull up to `n` events out of the inbox, in arrival order. Fails the
/// test (via `let assert`) if fewer than `n` events arrive within the
/// timeout.
fn collect(subject: process.Subject(ErrorEvent), n: Int) -> List(ErrorEvent) {
  case n {
    0 -> []
    _ -> {
      let assert Ok(event) = process.receive(subject, 1000)
      [event, ..collect(subject, n - 1)]
    }
  }
}

// Tests

/// A freshly started manager has no handlers registered.
pub fn fresh_manager_has_no_handlers_test() {
  let assert Ok(manager) = terminal_logger.start()
  assert event_manager.which_handlers(manager) == Ok([])
  terminal_logger.stop(manager)
}

/// `notify` broadcasts to every currently registered handler.
pub fn notify_broadcasts_to_all_handlers_test() {
  let assert Ok(manager) = terminal_logger.start()

  let inbox: process.Subject(ErrorEvent) = process.new_subject()
  let _ref = install_collector(manager, inbox)

  terminal_logger.report(manager, "first")
  terminal_logger.report(manager, "second")

  collect(inbox, 2)
  |> should.equal([Reported("first"), Reported("second")])

  terminal_logger.stop(manager)
}

/// All registered handlers see the same event in a single broadcast.
pub fn fan_out_delivers_to_multiple_handlers_test() {
  let assert Ok(manager) = terminal_logger.start()

  let inbox_a = process.new_subject()
  let inbox_b = process.new_subject()
  let _ = install_collector(manager, inbox_a)
  let _ = install_collector(manager, inbox_b)

  terminal_logger.report(manager, "broadcast")

  collect(inbox_a, 1) |> should.equal([Reported("broadcast")])
  collect(inbox_b, 1) |> should.equal([Reported("broadcast")])

  terminal_logger.stop(manager)
}

/// Removing a handler stops it from receiving subsequent events; other
/// handlers continue to see them.
pub fn removed_handler_stops_receiving_events_test() {
  let assert Ok(manager) = terminal_logger.start()

  let inbox_kept = process.new_subject()
  let inbox_removed = process.new_subject()
  let _ = install_collector(manager, inbox_kept)
  let ref_removed = install_collector(manager, inbox_removed)

  terminal_logger.report(manager, "before")

  let assert Ok(Nil) = event_manager.remove_handler(manager, ref_removed, 1000)

  terminal_logger.report(manager, "after")

  collect(inbox_kept, 2)
  |> should.equal([Reported("before"), Reported("after")])
  collect(inbox_removed, 1) |> should.equal([Reported("before")])

  terminal_logger.stop(manager)
}

/// The file_logger appends one formatted line per event to the given
/// path.
pub fn file_logger_appends_each_event_to_file_test() {
  let assert Ok(manager) = terminal_logger.start()

  let path = "/tmp/eparch_terminal_logger_file_appends_test.log"
  let _ = simplifile.delete(path)
  let assert Ok(_ref) =
    terminal_logger.add_file_logger(manager, path, on_error: fn(_) {
      panic as "unexpected write failure"
    })

  // Use sync_notify so we know the file has been written before reading.
  assert event_manager.sync_notify(manager, Reported("alpha"), 1000)
    == event_manager.Confirmed
  assert event_manager.sync_notify(manager, Reported("beta"), 1000)
    == event_manager.Confirmed

  let assert Ok(contents) = simplifile.read(path)
  contents
  |> should.equal("***Error*** alpha\n***Error*** beta\n")

  let _ = simplifile.delete(path)
  terminal_logger.stop(manager)
}

/// The terminal_logger handler registers cleanly and shows up in
/// `which_handlers`.
pub fn terminal_logger_registers_with_manager_test() {
  let assert Ok(manager) = terminal_logger.start()

  let assert Ok(_ref) = terminal_logger.add_terminal_logger(manager)
  let assert Ok(handlers) = event_manager.which_handlers(manager)
  assert list.length(handlers) == 1

  terminal_logger.stop(manager)
}

pub fn completed_callback_reports_failed_file_write_test() {
  let assert Ok(manager) = terminal_logger.start()
  let failures = process.new_subject()
  let path = "missing-eparch-test-directory/events.log"
  let assert Ok(_) =
    terminal_logger.add_file_logger(manager, path, on_error: process.send(
      failures,
      _,
    ))
  assert event_manager.sync_notify(manager, Reported("hello"), 1000)
    == event_manager.Confirmed
  assert process.receive(failures, 1000)
    == Ok(terminal_logger.WriteFailure(path, "hello", simplifile.Enoent))
  assert terminal_logger.stop(manager) == Ok(Nil)
}
