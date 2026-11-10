import eparch/event_manager
import gleam/int
import gleam/io
import gleam/option.{None}
import simplifile

/// The event broadcast across the bus. Plays the role of the `ErrorMsg`
/// term in the Erlang docs example.
pub type ErrorEvent {
  Reported(message: String)
}

/// Start an unnamed broadcast manager linked to the caller.
pub fn start() -> Result(
  event_manager.Manager(ErrorEvent),
  event_manager.StartError,
) {
  event_manager.start_link(event_manager.new_start_options())
}

/// Ask the manager to stop and its handlers to drain.
pub fn stop(
  manager: event_manager.Manager(ErrorEvent),
) -> Result(Nil, event_manager.StopError) {
  event_manager.stop(manager, 1000)
}

/// Broadcast an error to every registered handler.
///
/// Asynchronous: returns after sending to the manager.
pub fn report(
  manager: event_manager.Manager(ErrorEvent),
  message: String,
) -> Nil {
  event_manager.notify(manager, Reported(message))
}

/// Add a terminal logger.
///
/// State is the number of events the handler has seen so far. On
/// termination the handler prints a one-line summary.
pub fn add_terminal_logger(
  manager: event_manager.Manager(ErrorEvent),
) -> Result(event_manager.HandlerRef(ErrorEvent), event_manager.AddError) {
  let handler =
    event_manager.new_handler(0, fn(event, count) {
      let Reported(message) = event
      io.println("***Error*** " <> message)
      event_manager.Continue(count + 1)
    })
    |> event_manager.on_terminate(fn(count) {
      io.println(
        "terminal_logger removed after " <> int.to_string(count) <> " events",
      )
    })

  event_manager.add_handler(manager, handler, on_down: None)
}

pub type WriteFailure {
  WriteFailure(path: String, message: String, cause: simplifile.FileError)
}

/// Add a file logger that attempts to append every event to `path`.
/// A confirmation means the attempt finished; failures go to `on_error`.
///
/// State is the destination path. The file is opened (and the line
/// flushed) on every event via `simplifile.append`, mirroring the
/// behaviour of the Erlang docs example without managing a long-lived
/// file descriptor.
pub fn add_file_logger(
  manager: event_manager.Manager(ErrorEvent),
  path: String,
  on_error on_error: fn(WriteFailure) -> Nil,
) -> Result(event_manager.HandlerRef(ErrorEvent), event_manager.AddError) {
  let handler =
    event_manager.new_handler(path, fn(event, path) {
      let Reported(message) = event
      case simplifile.append(to: path, contents: format(message)) {
        Ok(Nil) -> Nil
        Error(cause) -> on_error(WriteFailure(path, message, cause))
      }
      event_manager.Continue(path)
    })

  event_manager.add_handler(manager, handler, on_down: None)
}

fn format(message: String) -> String {
  "***Error*** " <> message <> "\n"
}
