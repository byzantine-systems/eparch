import caller_fixture
import eparch/effect as e
import eparch/machine as m
import eparch/machine/otp
import eparch/state_machine as sm
import gleam/erlang/process
import gleam/list
import gleam/option.{Some}
import qcheck

type Command {
  Hold(Int)
  Change
  Repeat
  Snapshot
  Mark(Int)
}

type TimerCommand {
  Arm(e.TimeoutTime)
  Fired(e.From(Int))
}

fn timer_handler(
  input: m.Input(TimerCommand, Int),
  _: Nil,
  _: Nil,
) -> m.Step(Nil, Nil, TimerCommand, Int) {
  case input {
    m.Call(from, Arm(delay)) ->
      m.KeepStateAndData([e.StateTimeout(delay, Fired(from))])
    m.Timeout(e.StateTimer, Fired(from)) ->
      m.StopAndReply(process.Normal, [#(from, 1)])
    _ -> m.KeepStateAndData([])
  }
}

pub fn due_deadlines_reply_in_both_interpreters_test() {
  let from = caller_fixture.token()
  list.each([e.After(-5), e.After(0), e.At(-1_000_000_000_000_000)], fn(time) {
    let pure = m.new(Nil, Nil, timer_handler)
    let #(effects, final) = m.step(pure, m.Call(from, Arm(time)))
    assert m.is_stopped(final)
    assert list.contains(effects, e.Reply(from, 1))
    let assert Ok(server) =
      otp.builder(
        phase: Nil,
        data: Nil,
        handler: timer_handler,
        on_enter: option.None,
      )
      |> sm.start_link
    let request = sm.send_request(server.ref, Arm(time))
    assert sm.receive_response(request, 1000) == Ok(1)
  })
}

fn handle(input, phase, trace) {
  case input {
    m.Cast(Hold(_)) if !phase -> m.KeepStateAndData([e.Postpone])
    m.Cast(Hold(n)) | m.Internal(Mark(n)) | m.Timeout(_, Mark(n)) ->
      m.KeepState([n, ..trace], [])
    m.Cast(Change) ->
      m.NextState(!phase, trace, [
        e.StateTimeout(e.After(0), Mark(-1)),
        e.NextEvent(e.InternalEvent, Mark(-2)),
      ])
    m.Cast(Repeat) -> m.RepeatStateAndData([])
    m.Call(from, Snapshot) ->
      m.StopAndReply(process.Normal, [#(from, list.reverse(trace))])
    _ -> m.KeepStateAndData([])
  }
}

fn enter(_, trace) {
  m.EnterKeep([-3, ..trace], [e.EntryArm(e.StateTimer, e.After(0), Mark(-4))])
}

pub fn otp_and_logical_machine_deliver_the_same_trace_test() {
  let cmd =
    qcheck.from_weighted_generators(
      #(3, qcheck.map(qcheck.bounded_int(0, 8), Hold)),
      [#(2, qcheck.return(Change)), #(1, qcheck.return(Repeat))],
    )
  use commands <- qcheck.given(qcheck.generic_list(
    cmd,
    qcheck.bounded_int(0, 18),
  ))
  let assert Ok(server) =
    otp.builder(phase: False, data: [], handler: handle, on_enter: Some(enter))
    |> sm.start_link
  let #(_, model) =
    m.new(False, [], handle) |> m.with_state_enter(enter) |> m.begin
  let model =
    list.fold(commands, model, fn(model, cmd) {
      sm.cast(server.ref, cmd)
      let #(_, next) = m.step(model, m.Cast(cmd))
      next
    })
  // Same-sender ordering makes this call a fence after the external casts.
  let request = sm.send_request(server.ref, Snapshot)
  assert sm.receive_response(request, 1000) == Ok(list.reverse(m.data(model)))
}
