import eparch/event_manager
import gleam/int
import gleam/io
import simplifile

/// The event broadcast across the bus. Plays the role of the `ErrorMsg`
/// term in the Erlang docs example.
pub type ErrorEvent {
  Reported(message: String)
}

/// Start an unnamed `gen_event` manager linked to the caller.
pub fn start() -> Result(
  event_manager.Manager(ErrorEvent),
  event_manager.StartError,
) {
  event_manager.start_link(event_manager.new_start_options())
}

/// Stop the event manager. Every registered handler's `on_terminate`
/// callback runs before the process exits.
pub fn stop(manager: event_manager.Manager(ErrorEvent)) -> Nil {
  event_manager.stop(manager)
}

/// Broadcast an error to every registered handler.
///
/// Asynchronous: returns as soon as the manager has accepted the event,
/// without waiting for handlers to finish processing.
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
) -> Result(
  event_manager.HandlerRef(Nil, Nil),
  event_manager.AddError(Nil, Nil),
) {
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

  event_manager.add_handler(manager, handler)
}

/// Add a file logger that appends every event to `path`.
///
/// State is the destination path. The file is opened (and the line
/// flushed) on every event via `simplifile.append`, mirroring the
/// behaviour of the Erlang docs example without managing a long-lived
/// file descriptor.
pub fn add_file_logger(
  manager: event_manager.Manager(ErrorEvent),
  path: String,
) -> Result(
  event_manager.HandlerRef(Nil, Nil),
  event_manager.AddError(Nil, Nil),
) {
  let handler =
    event_manager.new_handler(path, fn(event, path) {
      let Reported(message) = event
      let _ = simplifile.append(to: path, contents: format(message))
      event_manager.Continue(path)
    })

  event_manager.add_handler(manager, handler)
}

fn format(message: String) -> String {
  "***Error*** " <> message <> "\n"
}
