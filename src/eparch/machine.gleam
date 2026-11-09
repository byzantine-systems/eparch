//// A logical-clock interpreter for state-machine transitions.
////
//// A `Machine` is an ordinary value: a phase, the user data, an armed-timer
//// set, a pending delivery queue, and a list of postponed inputs, plus the
//// callbacks that decide what a transition does. Nothing here owns a
//// process. You drive it explicitly with `step` (deliver one input) and
//// `advance_time` (move the logical clock), which makes whole execution
//// traces testable without spawning anything — the property suite in
//// `test/machine_property_test` relies on exactly that.
////
//// ## Semantics
////
//// The core reproduces the `gen_statem` event model, in the engine's own
//// order:
////
//// - the transition's effect list is resolved (last decision per timer
////   class wins) and its replies reported;
//// - on a state change the old *state* timer is canceled, the enter
////   callback fires with the previous phase, and every postponed input is
////   re-queued oldest-first ahead of previously queued events;
//// - `RepeatState` re-fires the enter callback *without* being a state
////   change, so the state timer survives;
//// - `NextEvent` effects are inserted at the very front of the queue, so
////   they are handled before postponed retries and before any new external
////   input;
//// - any delivered input cancels the *event* timer;
//// - arming or updating a timer with zero or elapsed time enqueues its
////   `Timeout` input as the newest event (after inserted and postponed
////   ones), and a zero *event* timer is only enqueued when the queue is
////   empty;
//// - canceling a timer also discards its not-yet-delivered `Timeout` input.
////
//// ## Laws
////
//// Two structural laws hold for every machine and are checked with
//// generated command scripts:
////
//// - **Trace composition:** running `xs <> ys` in one go agrees with running
////   `xs`, then running `ys` from the residual machine — same total effects,
////   same residual observations.
//// - **Determinism:** stepping the same machine twice with the same input
////   yields the same effects and residual observations.
////
//// Behavioural laws (postpone redelivery order, timer scoping, enter
//// firing) are checked per-step in the same suite.
////

import eparch/effect.{type Effect, type From, type TimeoutTime, type TimerKind}
import gleam/erlang/process.{type ExitReason}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order.{type Order}

/// One input delivered to a machine.
///
/// The logical interpreter permits injecting any input to replay a trace.
/// The OTP shell distinguishes real external traffic from inserted events.
///
pub type Input(msg, reply) {
  Cast(message: msg)
  Info(message: msg)
  Internal(message: msg)
  Call(from: From(reply), message: msg)
  Timeout(timer: TimerKind, content: msg)
}

/// What a handler decides for one input.
///
pub type Step(state, data, msg, reply) {
  /// Transition to `state`. If it differs from the current phase this is a
  /// state change: the state timer is canceled, the enter callback fires,
  /// and postponed inputs are retried.
  NextState(state: state, data: data, effects: List(Effect(msg, reply)))

  /// Keep the phase, replace the data.
  KeepState(data: data, effects: List(Effect(msg, reply)))

  /// Keep both phase and data.
  KeepStateAndData(effects: List(Effect(msg, reply)))

  /// Re-fire the enter callback (when enabled) without being a state
  /// change: the state timer survives.
  RepeatState(data: data, effects: List(Effect(msg, reply)))

  /// `RepeatState` without touching the data.
  RepeatStateAndData(effects: List(Effect(msg, reply)))

  /// Stop. Any further inputs are ignored.
  Stop(reason: ExitReason)

  /// Stop, but first send the given replies.
  StopAndReply(reason: ExitReason, replies: List(#(From(reply), reply)))
}

/// The restricted step an enter callback may return.
///
/// Entering a state cannot change the phase, postpone the (non-)event, or
/// insert events; those decisions are absent from `EntryEffect`.
///
pub type EnterStep(data, msg, reply) {
  EnterKeep(data: data, effects: List(effect.EntryEffect(msg, reply)))
  EnterKeepData(effects: List(effect.EntryEffect(msg, reply)))
}

type ArmedTimer(msg) {
  ArmedTimer(kind: TimerKind, deadline: Int, content: msg, armed_at: Int)
}

type Queued(msg, reply) {
  Queued(input: Input(msg, reply), from_timer: Option(TimerKind))
}

/// A pure state machine value.
///
pub opaque type Machine(state, data, msg, reply) {
  Machine(
    handler: fn(Input(msg, reply), state, data) -> Step(state, data, msg, reply),
    on_enter: Option(fn(state, data) -> EnterStep(data, msg, reply)),
    clock: Int,
    phase: state,
    data: data,
    timers: List(ArmedTimer(msg)),
    postponed: List(Input(msg, reply)),
    queue: List(Queued(msg, reply)),
    stopped: Option(ExitReason),
    next_armed_at: Int,
    initialised: Bool,
  )
}

const delivery_fuel = 65_536

/// Build a machine in its initial phase with the given data and handler.
///
/// The first drive runs the initial entry before delivering input. Use
/// `begin` to observe its effects separately.
///
pub fn new(
  phase phase: state,
  data data: data,
  handler handler: fn(Input(msg, reply), state, data) ->
    Step(state, data, msg, reply),
) -> Machine(state, data, msg, reply) {
  Machine(
    handler: handler,
    on_enter: None,
    clock: 0,
    phase: phase,
    data: data,
    timers: [],
    postponed: [],
    queue: [],
    stopped: None,
    next_armed_at: 0,
    initialised: False,
  )
}

/// Enable the enter callback, called on every state change with the previous
/// phase, and on the initial `begin`, and on `RepeatState`.
///
pub fn with_state_enter(
  machine: Machine(state, data, msg, reply),
  on_enter on_enter: fn(state, data) -> EnterStep(data, msg, reply),
) -> Machine(state, data, msg, reply) {
  Machine(..machine, on_enter: Some(on_enter))
}

/// Deliver the initial enter callback, if enabled.
///
/// Returns its effects and the machine ready to receive inputs. Calling
/// `begin` on a machine without an enter callback is a no-op.
///
pub fn begin(
  machine: Machine(state, data, msg, reply),
) -> #(List(Effect(msg, reply)), Machine(state, data, msg, reply)) {
  case machine.initialised {
    True -> #([], machine)
    False -> resume(machine, delivery_fuel)
  }
}

fn initialise(
  machine: Machine(state, data, msg, reply),
) -> #(List(Effect(msg, reply)), Machine(state, data, msg, reply)) {
  case machine.initialised {
    True -> #([], machine)
    False -> {
      let #(effects, entered) =
        fire_enter(Machine(..machine, initialised: True), machine.phase)
      #(effects, apply_timers(entered, effects))
    }
  }
}

/// Deliver one input and return the transition's effects plus the residual
/// machine.
///
/// Delivering an input to a stopped machine is a defined no-op: no effects,
/// unchanged machine.
///
pub fn step(
  machine: Machine(state, data, msg, reply),
  input: Input(msg, reply),
) -> #(List(Effect(msg, reply)), Machine(state, data, msg, reply)) {
  step_with_budget(machine, input, delivery_fuel)
}

/// Queue an input and process up to `budget` inputs. Inspect `progress` on
/// the returned machine before treating its data as a settled observation.
pub fn step_with_budget(
  machine: Machine(state, data, msg, reply),
  input: Input(msg, reply),
  budget: Int,
) -> #(List(Effect(msg, reply)), Machine(state, data, msg, reply)) {
  case machine.stopped {
    Some(_) -> #([], machine)
    None -> {
      let #(entry, machine) = initialise(machine)
      settle(enqueue_newest(machine, input, None), budget, entry)
    }
  }
}

pub type Progress {
  Settled
  NeedsResume
}

/// Whether there is runnable work left at the current logical instant.
pub fn progress(machine: Machine(state, data, msg, reply)) -> Progress {
  case machine.queue, machine.stopped {
    [_, ..], None -> NeedsResume
    _, _ -> Settled
  }
}

/// Continue queued work without adding an input or advancing the clock.
pub fn resume(
  machine: Machine(state, data, msg, reply),
  budget: Int,
) -> #(List(Effect(msg, reply)), Machine(state, data, msg, reply)) {
  let #(entry, machine) = initialise(machine)
  settle(machine, budget, entry)
}

/// Advance the logical clock by `milliseconds`, turning every timer whose
/// deadline has been reached into a delivered `Timeout` input, newest after
/// any already-queued events, then settling the whole queue.
/// This is a clock jump: a callback rearming a relative timer uses the new
/// clock reading rather than the nominal deadline of the expired timer.
///
pub fn advance_time(
  machine: Machine(state, data, msg, reply),
  milliseconds: Int,
) -> #(List(Effect(msg, reply)), Machine(state, data, msg, reply)) {
  let #(entry, machine) = begin(machine)
  case machine.stopped {
    Some(_) -> #(entry, machine)
    None -> {
      let machine =
        Machine(..machine, clock: machine.clock + int.max(0, milliseconds))
      let machine = enqueue_due(machine)
      settle(machine, delivery_fuel, entry)
    }
  }
}

fn enqueue_due(
  machine: Machine(state, data, msg, reply),
) -> Machine(state, data, msg, reply) {
  let due =
    machine.timers
    |> list.filter(fn(timer) { timer.deadline <= machine.clock })
    |> list.sort(due_compare)
  case due {
    [] -> machine
    [_, ..] ->
      list.fold(due, machine, fn(machine, timer) {
        let machine =
          Machine(
            ..machine,
            timers: list.filter(machine.timers, fn(other) {
              other.armed_at != timer.armed_at
            }),
          )
        enqueue_newest(
          machine,
          Timeout(timer.kind, timer.content),
          Some(timer.kind),
        )
      })
  }
}

fn due_compare(a: ArmedTimer(msg), b: ArmedTimer(msg)) -> Order {
  case int.compare(a.deadline, b.deadline) {
    order.Eq -> int.compare(a.armed_at, b.armed_at)
    other -> other
  }
}

fn settle(
  machine: Machine(state, data, msg, reply),
  fuel: Int,
  collected: List(Effect(msg, reply)),
) -> #(List(Effect(msg, reply)), Machine(state, data, msg, reply)) {
  settle_loop(machine, fuel, list.reverse(collected))
}

fn settle_loop(
  machine: Machine(state, data, msg, reply),
  fuel: Int,
  reversed: List(Effect(msg, reply)),
) -> #(List(Effect(msg, reply)), Machine(state, data, msg, reply)) {
  case machine.queue, machine.stopped, fuel <= 0 {
    [], _, _ | _, Some(_), _ | _, _, True -> #(list.reverse(reversed), machine)
    [first, ..rest], None, False -> {
      let machine = Machine(..machine, queue: rest)
      let #(effects, machine) = process(machine, first.input)
      settle_loop(
        machine,
        fuel - 1,
        list.fold(effects, reversed, fn(acc, effect) { [effect, ..acc] }),
      )
    }
  }
}

fn process(
  machine: Machine(state, data, msg, reply),
  input: Input(msg, reply),
) -> #(List(Effect(msg, reply)), Machine(state, data, msg, reply)) {
  case machine.stopped {
    Some(_) -> #([], machine)
    None -> {
      let machine = cancel_timer(machine, effect.EventTimer)
      let step_result = machine.handler(input, machine.phase, machine.data)
      transition(machine, input, step_result)
    }
  }
}

fn transition(
  machine: Machine(state, data, msg, reply),
  input: Input(msg, reply),
  step_result: Step(state, data, msg, reply),
) -> #(List(Effect(msg, reply)), Machine(state, data, msg, reply)) {
  case step_result {
    NextState(next, data, effects) -> {
      let effects = effect.resolve(effects)
      let old = machine.phase
      let changed = next != old
      let machine = Machine(..machine, phase: next, data: data)
      let #(enter_effects, machine) = case changed {
        True -> {
          let machine = cancel_timer(machine, effect.StateTimer)
          fire_enter(machine, old)
        }
        False -> #([], machine)
      }
      let machine = postpone_current(machine, input, effects)
      let machine = case changed {
        True ->
          Machine(
            ..machine,
            queue: list.append(
              postponed_as_queued(machine.postponed),
              machine.queue,
            ),
            postponed: [],
          )
        False -> machine
      }
      let machine = insert_next_events(machine, effects)
      let effects = effect.resolve(list.append(effects, enter_effects))
      #(effects, apply_timers(machine, effects))
    }

    KeepState(data, effects) -> keep_like(machine, input, effects, data, False)
    KeepStateAndData(effects) ->
      keep_like(machine, input, effects, machine.data, False)
    RepeatState(data, effects) -> keep_like(machine, input, effects, data, True)
    RepeatStateAndData(effects) ->
      keep_like(machine, input, effects, machine.data, True)

    Stop(reason) -> #([], Machine(..machine, stopped: Some(reason)))

    StopAndReply(reason, replies) -> {
      let machine = Machine(..machine, stopped: Some(reason))
      let effects =
        list.map(replies, fn(pair) {
          let #(to, response) = pair
          effect.Reply(to, response)
        })
      #(effects, machine)
    }
  }
}

fn keep_like(
  machine: Machine(state, data, msg, reply),
  input: Input(msg, reply),
  effects: List(Effect(msg, reply)),
  data: data,
  repeat: Bool,
) -> #(List(Effect(msg, reply)), Machine(state, data, msg, reply)) {
  let effects = effect.resolve(effects)
  let machine = Machine(..machine, data: data)
  let #(enter_effects, machine) = case repeat {
    True -> fire_enter(machine, machine.phase)
    False -> #([], machine)
  }
  let machine = postpone_current(machine, input, effects)
  let machine = insert_next_events(machine, effects)
  let effects = effect.resolve(list.append(effects, enter_effects))
  #(effects, apply_timers(machine, effects))
}

fn fire_enter(
  machine: Machine(state, data, msg, reply),
  old: state,
) -> #(List(Effect(msg, reply)), Machine(state, data, msg, reply)) {
  case machine.on_enter, machine.stopped {
    Some(enter), None -> {
      let enter_step = enter(old, machine.data)
      let #(data, effects) = case enter_step {
        EnterKeep(data, effects) -> #(data, effects)
        EnterKeepData(effects) -> #(machine.data, effects)
      }
      let machine = Machine(..machine, data: data)
      let effects = effect.resolve(list.map(effects, effect.from_entry))
      #(effects, machine)
    }
    _, _ -> #([], machine)
  }
}

fn postpone_current(
  machine: Machine(state, data, msg, reply),
  input: Input(msg, reply),
  effects: List(Effect(msg, reply)),
) -> Machine(state, data, msg, reply) {
  case list.any(effects, fn(e) { e == effect.Postpone }) {
    True ->
      Machine(..machine, postponed: list.append(machine.postponed, [input]))
    False -> machine
  }
}

fn postponed_as_queued(
  postponed: List(Input(msg, reply)),
) -> List(Queued(msg, reply)) {
  list.map(postponed, fn(input) { Queued(input, None) })
}

fn insert_next_events(
  machine: Machine(state, data, msg, reply),
  effects: List(Effect(msg, reply)),
) -> Machine(state, data, msg, reply) {
  let inserted =
    list.filter_map(effects, fn(e) {
      case e {
        effect.NextEvent(kind, content) ->
          Ok(case kind {
            effect.InternalEvent -> Internal(content)
            effect.CastEvent -> Cast(content)
            effect.InfoEvent -> Info(content)
            effect.CallEvent(from) -> Call(from, content)
          })
        _ -> Error(Nil)
      }
    })
  case inserted {
    [] -> machine
    _ ->
      Machine(
        ..machine,
        queue: list.append(
          list.map(inserted, fn(i) { Queued(i, None) }),
          machine.queue,
        ),
      )
  }
}

fn apply_timers(
  machine: Machine(state, data, msg, reply),
  effects: List(Effect(msg, reply)),
) -> Machine(state, data, msg, reply) {
  list.fold(effects, machine, fn(machine, e) {
    case e {
      effect.StateTimeout(time, content) ->
        arm_timer(machine, effect.StateTimer, time, content)
      effect.EventTimeout(time, content) ->
        arm_timer(machine, effect.EventTimer, time, content)
      effect.GenericTimeout(id, time, content) ->
        arm_timer(machine, effect.GenericTimer(id), time, content)
      effect.CancelStateTimeout -> cancel_timer(machine, effect.StateTimer)
      effect.CancelEventTimeout -> cancel_timer(machine, effect.EventTimer)
      effect.CancelGenericTimeout(id) ->
        cancel_timer(machine, effect.GenericTimer(id))
      effect.UpdateStateTimeout(content) ->
        update_timer(machine, effect.StateTimer, content)
      effect.UpdateEventTimeout(content) ->
        update_timer(machine, effect.EventTimer, content)
      effect.UpdateGenericTimeout(id, content) ->
        update_timer(machine, effect.GenericTimer(id), content)
      effect.Reply(..)
      | effect.Postpone
      | effect.NextEvent(..)
      | effect.Hibernate -> machine
    }
  })
}

fn enqueue_newest(
  machine: Machine(state, data, msg, reply),
  input: Input(msg, reply),
  from_timer: Option(TimerKind),
) -> Machine(state, data, msg, reply) {
  Machine(
    ..machine,
    queue: list.append(machine.queue, [Queued(input, from_timer)]),
  )
}

fn arm_timer(
  machine: Machine(state, data, msg, reply),
  kind: TimerKind,
  time: TimeoutTime,
  content: msg,
) -> Machine(state, data, msg, reply) {
  let deadline = effect.deadline_from(machine.clock, time)
  let machine = cancel_timer(machine, kind)
  case deadline <= machine.clock {
    True ->
      case kind, machine.queue {
        effect.EventTimer, [_, ..] -> machine
        _, _ -> enqueue_newest(machine, Timeout(kind, content), Some(kind))
      }
    False -> {
      let timer =
        ArmedTimer(
          kind: kind,
          deadline: deadline,
          content: content,
          armed_at: machine.next_armed_at,
        )
      Machine(
        ..machine,
        timers: list.append(machine.timers, [timer]),
        next_armed_at: machine.next_armed_at + 1,
      )
    }
  }
}

fn cancel_timer(
  machine: Machine(state, data, msg, reply),
  kind: TimerKind,
) -> Machine(state, data, msg, reply) {
  Machine(
    ..machine,
    timers: list.filter(machine.timers, fn(timer) { timer.kind != kind }),
    queue: list.filter(machine.queue, fn(queued) {
      case queued.from_timer {
        Some(armed) -> armed != kind
        None -> True
      }
    }),
  )
}

fn update_timer(
  machine: Machine(state, data, msg, reply),
  kind: TimerKind,
  content: msg,
) -> Machine(state, data, msg, reply) {
  let running = list.find(machine.timers, fn(timer) { timer.kind == kind })
  case running {
    Ok(timer) -> {
      let timers =
        list.map(machine.timers, fn(candidate) {
          case candidate.armed_at == timer.armed_at {
            True -> ArmedTimer(..candidate, content: content)
            False -> candidate
          }
        })
      Machine(..machine, timers: timers)
    }
    Error(_) ->
      case list.any(machine.queue, fn(q) { q.from_timer == Some(kind) }) {
        True ->
          Machine(
            ..machine,
            queue: list.map(machine.queue, fn(q) {
              case q.from_timer == Some(kind) {
                True -> Queued(Timeout(kind, content), Some(kind))
                False -> q
              }
            }),
          )
        False -> arm_timer(machine, kind, effect.After(0), content)
      }
  }
}

/// The current phase.
///
pub fn phase(machine: Machine(state, data, msg, reply)) -> state {
  machine.phase
}

/// The current data.
///
pub fn data(machine: Machine(state, data, msg, reply)) -> data {
  machine.data
}

/// The current logical clock, advanced by `advance_time`.
///
pub fn clock(machine: Machine(state, data, msg, reply)) -> Int {
  machine.clock
}

/// Whether the machine has stopped.
///
pub fn is_stopped(machine: Machine(state, data, msg, reply)) -> Bool {
  machine.stopped != None
}

/// Why the machine stopped, if it has.
///
pub fn stop_reason(
  machine: Machine(state, data, msg, reply),
) -> Option(ExitReason) {
  machine.stopped
}

/// The timers currently armed: kind, remaining milliseconds, and payload.
///
pub fn pending_timeouts(
  machine: Machine(state, data, msg, reply),
) -> List(#(TimerKind, Int, msg)) {
  list.map(machine.timers, fn(timer) {
    #(timer.kind, timer.deadline - machine.clock, timer.content)
  })
}

/// The inputs currently postponed, oldest first.
///
pub fn postponed_inputs(
  machine: Machine(state, data, msg, reply),
) -> List(Input(msg, reply)) {
  machine.postponed
}
