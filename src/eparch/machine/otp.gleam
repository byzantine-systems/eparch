//// Run the same transition functions used by `eparch/machine` in a real
//// `gen_statem`. OTP owns the queue, timers, caller tokens and entry calls.

import eparch/effect as e
import eparch/machine as m
import eparch/state_machine as sm
import gleam/list
import gleam/option.{type Option, None, Some}

/// Start from an initial phase and data. The optional entry callback can
/// only return entry-safe effects. Untagged mailbox terms are ignored.
pub fn builder(
  phase: phase,
  data: data,
  handle: fn(m.Input(msg, reply), phase, data) ->
    m.Step(phase, data, msg, reply),
  on_enter enter: Option(fn(phase, data) -> m.EnterStep(data, msg, reply)),
) -> sm.Builder(phase, data, msg, reply) {
  let builder = sm.new(phase, data)
  let builder = case enter {
    Some(_) -> sm.with_state_enter(builder)
    None -> builder
  }
  use event, phase, data <- sm.on_event(builder)
  case event {
    sm.Enter(old) ->
      case enter {
        None -> sm.KeepStateAndData([])
        Some(enter) ->
          case enter(old, data) {
            m.EnterKeep(data, effects) ->
              sm.KeepState(data, list.map(effects, entry_action))
            m.EnterKeepData(effects) ->
              sm.KeepStateAndData(list.map(effects, entry_action))
          }
      }
    sm.RawInfo(_) -> sm.KeepStateAndData([])
    sm.Call(from, msg) -> step(handle(m.Call(from, msg), phase, data))
    sm.Cast(msg) -> step(handle(m.Cast(msg), phase, data))
    sm.Info(msg) -> step(handle(m.Info(msg), phase, data))
    sm.Internal(msg) -> step(handle(m.Internal(msg), phase, data))
    sm.Timeout(kind, msg) -> {
      let timer = case kind {
        sm.StateTimeoutType -> e.StateTimer
        sm.EventTimeoutType -> e.EventTimer
        sm.GenericTimeoutType(key) -> e.GenericTimer(e.timer_id(key))
      }
      step(handle(m.Timeout(timer, msg), phase, data))
    }
  }
}

fn step(
  transition: m.Step(phase, data, message, reply),
) -> sm.Step(phase, data, message, reply) {
  case transition {
    m.NextState(phase, data, effects) ->
      sm.NextState(phase, data, list.map(effects, action))
    m.KeepState(data, effects) -> sm.KeepState(data, list.map(effects, action))
    m.KeepStateAndData(effects) ->
      sm.KeepStateAndData(list.map(effects, action))
    m.RepeatState(data, effects) ->
      sm.RepeatState(data, list.map(effects, action))
    m.RepeatStateAndData(effects) ->
      sm.RepeatStateAndData(list.map(effects, action))
    m.Stop(reason) -> sm.Stop(reason)
    m.StopAndReply(reason, replies) -> sm.StopAndReply(reason, replies)
  }
}

@external(erlang, "eparch_delivery_ffi", "now_ms")
fn monotonic_milliseconds() -> Int

fn time(t: e.TimeoutTime) -> sm.TimeoutTime {
  case e.normalise_time(t) {
    e.After(n) -> sm.After(n)
    e.At(deadline) ->
      case deadline <= monotonic_milliseconds() {
        True -> sm.After(0)
        False -> sm.At(deadline)
      }
  }
}

fn entry_action(
  effect: e.EntryEffect(message, reply),
) -> sm.Action(message, reply) {
  action(e.from_entry(effect))
}

fn action(effect: e.Effect(msg, reply)) -> sm.Action(msg, reply) {
  case effect {
    e.Reply(to, v) -> sm.Reply(to, v)
    e.Postpone -> sm.Postpone
    e.NextEvent(kind, v) ->
      sm.NextEvent(
        case kind {
          e.InternalEvent -> sm.InternalEvent
          e.CastEvent -> sm.CastEvent
          e.InfoEvent -> sm.InfoEvent
          e.CallEvent(from) -> sm.CallEvent(from)
        },
        v,
      )
    e.StateTimeout(t, v) -> sm.StateTimeout(time(t), v)
    e.EventTimeout(t, v) -> sm.EventTimeout(time(t), v)
    e.GenericTimeout(id, t, v) ->
      sm.GenericTimeout(e.timer_id_name(id), time(t), v)
    e.CancelStateTimeout -> sm.CancelStateTimeout
    e.CancelEventTimeout -> sm.CancelEventTimeout
    e.CancelGenericTimeout(id) -> sm.CancelGenericTimeout(e.timer_id_name(id))
    e.UpdateStateTimeout(v) -> sm.UpdateStateTimeout(v)
    e.UpdateEventTimeout(v) -> sm.UpdateEventTimeout(v)
    e.UpdateGenericTimeout(id, v) ->
      sm.UpdateGenericTimeout(e.timer_id_name(id), v)
    e.Hibernate -> sm.Hibernate
  }
}
