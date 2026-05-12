import eparch/state_machine as sm

// Types
pub type State {
  Off
  On
}

pub type Data {
  Data(count: Int)
}

pub type Message {
  Push
  GetCount
}

/// Replies are unified into one type because `gen_statem` uses a single
/// reply channel per machine.
pub type Reply {
  /// Toggle the button.
  /// A Push from Off -> On increments the counter.
  /// Push from On -> Off does not increment.
  PushReply(state: State)
  /// Query the press count without changing state.
  CountReply(count: Int)
}

/// Handle state machine events.
pub fn handle_event(
  event: sm.Event(State, Message, Reply),
  state: State,
  data: Data,
) -> sm.Step(State, Data, Message, Reply) {
  case event, state {
    // Off + Push -> On.
    // - Count increments
    // - Reply is the count *before* the change
    sm.Call(from, Push), Off ->
      sm.next_state(On, Data(count: data.count + 1), [
        sm.reply(from, PushReply(On)),
      ])

    // On + Push -> Off.
    // - Count is unchanged.
    sm.Call(from, Push), On ->
      sm.next_state(Off, data, [sm.reply(from, PushReply(Off))])

    // GetCount is valid in any state,
    // reply with count without changing state.
    sm.Call(from, GetCount), _ ->
      sm.keep_state(data, [sm.reply(from, CountReply(data.count))])

    // Any other event (casts, info, timeouts) is silently ignored.
    _, _ -> sm.keep_state(data, [])
  }
}

// Public API
/// Start the pushbutton with press count at 0 and initial state Off.
pub fn start() -> sm.StartResult(Message) {
  sm.new(initial_state: Off, initial_data: Data(count: 0))
  |> sm.on_event(handle_event)
  |> sm.start
}

/// Toggle the button and return the count *before* the toggle.
pub fn push(ref: sm.ServerRef(Message)) -> State {
  let request: sm.RequestId(Reply) = sm.send_request(ref, Push)
  let assert Ok(PushReply(new_state)) = sm.receive_response(request, 5000)
  new_state
}

/// Query the press count without changing state.
pub fn get_count(ref: sm.ServerRef(Message)) -> Int {
  let request: sm.RequestId(Reply) = sm.send_request(ref, GetCount)
  let assert Ok(CountReply(count)) = sm.receive_response(request, 5000)
  count
}
