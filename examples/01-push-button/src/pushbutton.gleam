import eparch/state_machine as sm
import gleam/erlang/process

// Types

pub type State {
  Off
  On
}

/// Both messages embed a reply Subject so the caller receives the count.
pub type Msg {
  /// Toggle the button.
  /// `Off -> On` increments the count, reply is the count *before* the toggle.
  /// `On -> Off` does not increment, reply is the current count.
  Push(reply_with: process.Subject(Int))

  /// Query the press count without changing state.
  GetCount(reply_with: process.Subject(Int))
}

// API
/// Start the pushbutton with press count at 0 and initial state Off.
pub fn start() -> Result(sm.Started(process.Subject(Msg)), sm.StartError) {
  sm.new(Off, 0)
  |> sm.on_event(handle_event)
  |> sm.start
}

/// Toggle the button and return the count *before* the toggle.
pub fn push(subject: process.Subject(Msg)) -> Int {
  process.call(subject, 5000, Push)
}

/// Query the press count without changing state.
pub fn get_count(subject: process.Subject(Msg)) -> Int {
  process.call(subject, 5000, GetCount)
}

// Event Handler
/// Handle state machine events.
pub fn handle_event(
  event: sm.Event(State, Msg, Nil),
  state: State,
  data: Int,
) -> sm.Step(State, Int, Msg, Nil) {
  case event, state {
    // Off + Push -> On.
    // - Count increments
    // - Reply is the count *before* the change
    sm.Info(Push(reply_sub)), Off -> {
      process.send(reply_sub, data)
      sm.next_state(On, data + 1, [])
    }

    // On + Push -> Off.
    // - Count is unchanged.
    // - Reply is the current count
    sm.Info(Push(reply_sub)), On -> {
      process.send(reply_sub, data)
      sm.next_state(Off, data, [])
    }

    // GetCount is valid in any state,
    // reply with count without changing state.
    sm.Info(GetCount(reply_sub)), _ -> {
      process.send(reply_sub, data)
      sm.keep_state(data, [])
    }

    // Any other event (casts, info, timeouts) is silently ignored.
    _, _ -> sm.keep_state(data, [])
  }
}
