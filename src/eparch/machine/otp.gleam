//// Run the same transition functions used by `eparch/machine` in a real
//// `gen_statem`. OTP owns the queue, timers, caller tokens and entry calls.
////
//// An `effect.At` deadline is read against `erlang:monotonic_time/1` here,
//// while `eparch/machine` reads it against its own logical clock, which
//// starts at zero. Relative `After` delays mean the same thing in both
//// interpreters; a future absolute deadline does not carry over between them.

import eparch/effect
import eparch/machine
import eparch/state_machine
import gleam/list
import gleam/option.{type Option, None, Some}

/// Build a `state_machine.Builder` that interprets the given transition
/// functions on `gen_statem`. The optional entry callback can only return
/// entry-safe effects. Untagged mailbox terms are ignored.
///
/// ## Example
///
/// ```gleam
/// let assert Ok(started) =
///   otp.builder(
///     phase: Idle,
///     data: 0,
///     handler: handle,
///     on_enter: option.Some(enter),
///   )
///   |> state_machine.start_link
/// ```
///
pub fn builder(
  phase phase: phase,
  data data: data,
  handler handler: fn(machine.Input(msg, reply), phase, data) ->
    machine.Step(phase, data, msg, reply),
  on_enter on_enter: Option(
    fn(phase, data) -> machine.EnterStep(data, msg, reply),
  ),
) -> state_machine.Builder(phase, data, msg, reply) {
  let builder = state_machine.new(phase, data)
  let builder = case on_enter {
    Some(_) -> state_machine.with_state_enter(builder)
    None -> builder
  }
  use event, phase, data <- state_machine.on_event(builder)
  case event {
    state_machine.Enter(old) ->
      case on_enter {
        None -> state_machine.KeepStateAndData([])
        Some(enter) ->
          case enter(old, data) {
            machine.EnterKeep(data, effects) ->
              state_machine.KeepState(data, list.map(effects, entry_action))
            machine.EnterKeepData(effects) ->
              state_machine.KeepStateAndData(list.map(effects, entry_action))
          }
      }
    state_machine.RawInfo(_) -> state_machine.KeepStateAndData([])
    state_machine.Call(from, msg) ->
      step(handler(machine.Call(from, msg), phase, data))
    state_machine.Cast(msg) -> step(handler(machine.Cast(msg), phase, data))
    state_machine.Info(msg) -> step(handler(machine.Info(msg), phase, data))
    state_machine.Internal(msg) ->
      step(handler(machine.Internal(msg), phase, data))
    state_machine.Timeout(kind, msg) -> {
      let timer = case kind {
        state_machine.StateTimeoutType -> effect.StateTimer
        state_machine.EventTimeoutType -> effect.EventTimer
        state_machine.GenericTimeoutType(key) ->
          effect.GenericTimer(effect.timer_id(key))
      }
      step(handler(machine.Timeout(timer, msg), phase, data))
    }
  }
}

fn step(
  transition: machine.Step(phase, data, message, reply),
) -> state_machine.Step(phase, data, message, reply) {
  case transition {
    machine.NextState(phase, data, effects) ->
      state_machine.NextState(phase, data, list.map(effects, action))
    machine.KeepState(data, effects) ->
      state_machine.KeepState(data, list.map(effects, action))
    machine.KeepStateAndData(effects) ->
      state_machine.KeepStateAndData(list.map(effects, action))
    machine.RepeatState(data, effects) ->
      state_machine.RepeatState(data, list.map(effects, action))
    machine.RepeatStateAndData(effects) ->
      state_machine.RepeatStateAndData(list.map(effects, action))
    machine.Stop(reason) -> state_machine.Stop(reason)
    machine.StopAndReply(reason, replies) ->
      state_machine.StopAndReply(reason, replies)
  }
}

@external(erlang, "eparch_delivery_ffi", "now_ms")
fn monotonic_milliseconds() -> Int

fn time(timeout: effect.TimeoutTime) -> state_machine.TimeoutTime {
  case effect.normalise_time(timeout) {
    effect.After(delay) -> state_machine.After(delay)
    effect.At(deadline) ->
      case deadline <= monotonic_milliseconds() {
        True -> state_machine.After(0)
        False -> state_machine.At(deadline)
      }
  }
}

fn entry_action(
  entry: effect.EntryEffect(message, reply),
) -> state_machine.Action(message, reply) {
  action(effect.from_entry(entry))
}

fn action(
  transition_effect: effect.Effect(msg, reply),
) -> state_machine.Action(msg, reply) {
  case transition_effect {
    effect.Reply(to, response) -> state_machine.Reply(to, response)
    effect.Postpone -> state_machine.Postpone
    effect.NextEvent(kind, content) ->
      state_machine.NextEvent(
        case kind {
          effect.InternalEvent -> state_machine.InternalEvent
          effect.CastEvent -> state_machine.CastEvent
          effect.InfoEvent -> state_machine.InfoEvent
          effect.CallEvent(from) -> state_machine.CallEvent(from)
        },
        content,
      )
    effect.StateTimeout(after, content) ->
      state_machine.StateTimeout(time(after), content)
    effect.EventTimeout(after, content) ->
      state_machine.EventTimeout(time(after), content)
    effect.GenericTimeout(id, after, content) ->
      state_machine.GenericTimeout(
        effect.timer_id_to_string(id),
        time(after),
        content,
      )
    effect.CancelStateTimeout -> state_machine.CancelStateTimeout
    effect.CancelEventTimeout -> state_machine.CancelEventTimeout
    effect.CancelGenericTimeout(id) ->
      state_machine.CancelGenericTimeout(effect.timer_id_to_string(id))
    effect.UpdateStateTimeout(content) ->
      state_machine.UpdateStateTimeout(content)
    effect.UpdateEventTimeout(content) ->
      state_machine.UpdateEventTimeout(content)
    effect.UpdateGenericTimeout(id, content) ->
      state_machine.UpdateGenericTimeout(effect.timer_id_to_string(id), content)
    effect.Hibernate -> state_machine.Hibernate
  }
}
