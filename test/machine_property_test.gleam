////
//// Laws of the pure machine core (`eparch/machine`), checked with
//// generated command scripts against small fixed handler fixtures, plus an
//// independent per-step model for the enter callback.
////

import caller_fixture
import eparch/effect
import eparch/machine.{type Input, type Machine, type Step, EnterKeep}
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option}
import qcheck

pub fn resuming_preserves_the_ordered_effect_trace_test() {
  use depth <- qcheck.given(qcheck.bounded_int(2, 30))
  let chain =
    machine.new(Nil, [], fn(input, _, seen) {
      case input {
        machine.Cast(n) if n > 0 ->
          machine.KeepState([n, ..seen], [
            effect.NextEvent(effect.CastEvent, n - 1),
            effect.Hibernate,
          ])
        _ -> machine.KeepState([0, ..seen], [])
      }
    })
  let #(whole, final) = machine.step(chain, machine.Cast(depth))
  let #(first, partial) =
    machine.step_with_budget(chain, machine.Cast(depth), 1)
  assert machine.progress(partial) == machine.NeedsResume
  let #(rest, resumed) = machine.resume(partial, depth)
  assert machine.progress(resumed) == machine.Settled
  assert list.append(first, rest) == whole
  assert machine.data(resumed) == machine.data(final)
}

// ---------------------------------------------------------------------------
// Workhorse machine: rich enough to exercise state changes, data changes,
// inserted internal events, postponement, timer arming, and replies.
// ---------------------------------------------------------------------------

fn workhorse() -> Machine(Int, Int, Int, Int) {
  machine.new(phase: 0, data: 0, handler: workhorse_handler)
}

fn workhorse_handler(
  input: Input(Int, Int),
  phase: Int,
  data: Int,
) -> Step(Int, Int, Int, Int) {
  case input {
    machine.Cast(n) ->
      case n < 0, n % 5 {
        True, _ -> machine.Stop(process.Normal)
        False, 0 -> machine.NextState(phase + 1, data + n, [])
        _, 1 -> machine.KeepState(data + n, [])
        _, 2 ->
          machine.KeepStateAndData([
            effect.NextEvent(effect.InternalEvent, n * 10),
          ])
        _, 3 -> machine.KeepState(data, [effect.Postpone])
        _, _ ->
          machine.KeepState(data, [
            effect.StateTimeout(effect.After(5 + n % 40), n * 7),
          ])
      }
    machine.Internal(x) -> machine.KeepState(data + x, [])
    machine.Info(x) ->
      machine.KeepState(data + x * 2, [
        effect.EventTimeout(effect.After(2 + x % 30), x),
      ])
    machine.Call(from, n) ->
      machine.KeepState(data + n, [effect.Reply(from, n * 100)])
    machine.Timeout(kind, content) ->
      case kind {
        effect.StateTimer -> machine.NextState(phase + 10, data + content, [])
        effect.EventTimer -> machine.KeepState(data + content * 3, [])
        effect.GenericTimer(_) -> machine.KeepState(data + content, [])
      }
  }
}

type Command {
  Deliver(input: Input(Int, Int))
  Wait(ms: Int)
}

fn input_gen() -> qcheck.Generator(Input(Int, Int)) {
  let n = qcheck.bounded_int(0, 60)
  let from = caller_fixture.token()
  qcheck.from_weighted_generators(#(5, qcheck.map(n, machine.Cast)), [
    #(2, qcheck.map(n, machine.Info)),
    #(1, qcheck.map(n, machine.Internal)),
    #(1, qcheck.map(n, machine.Call(from, _))),
  ])
}

fn command_gen() -> qcheck.Generator(Command) {
  qcheck.from_weighted_generators(#(4, qcheck.map(input_gen(), Deliver)), [
    #(1, qcheck.map(qcheck.bounded_int(0, 80), Wait)),
  ])
}

fn commands_gen() -> qcheck.Generator(List(Command)) {
  qcheck.generic_list(command_gen(), qcheck.bounded_int(0, 14))
}

fn run(
  start: Machine(Int, Int, Int, Int),
  commands: List(Command),
) -> #(List(effect.Effect(Int, Int)), Machine(Int, Int, Int, Int)) {
  list.fold(commands, #([], start), fn(acc, command) {
    let #(effects, m) = acc
    case command {
      Deliver(input) -> {
        let #(more, m) = machine.step(m, input)
        #(list.append(effects, more), m)
      }
      Wait(ms) -> {
        let #(more, m) = machine.advance_time(m, ms)
        #(list.append(effects, more), m)
      }
    }
  })
}

type Observation {
  Observation(
    phase: Int,
    data: Int,
    timers: List(#(effect.TimerKind, Int, Int)),
    stopped: Option(process.ExitReason),
    clock: Int,
    postponed: List(Input(Int, Int)),
    progress: machine.Progress,
  )
}

fn observe(m: Machine(Int, Int, Int, Int)) -> Observation {
  Observation(
    phase: machine.phase(m),
    data: machine.data(m),
    timers: machine.pending_timeouts(m),
    stopped: machine.stop_reason(m),
    clock: machine.clock(m),
    postponed: machine.postponed_inputs(m),
    progress: machine.progress(m),
  )
}

pub fn determinism_test() {
  use commands <- qcheck.given(commands_gen())
  let #(effects_a, a) = run(workhorse(), commands)
  let #(effects_b, b) = run(workhorse(), commands)
  assert effects_a == effects_b as "determinism-effects"
  assert observe(a) == observe(b) as "determinism-observations"
}

pub fn trace_composition_test() {
  use split <- qcheck.given(
    qcheck.bind(commands_gen(), fn(commands) {
      qcheck.map(qcheck.bounded_int(0, list.length(commands)), fn(at) {
        #(commands, at)
      })
    }),
  )
  let #(commands, at) = split
  let #(prefix, suffix) = list.split(commands, at)
  let #(whole_effects, whole) = run(workhorse(), commands)
  let #(first_effects, middle) = run(workhorse(), prefix)
  let #(second_effects, rest) = run(middle, suffix)
  assert whole_effects == list.append(first_effects, second_effects)
    as "composition-effects"
  assert observe(whole) == observe(rest) as "composition-residual"
}

pub fn stopped_machine_ignores_everything_test() {
  use pair <- qcheck.given(qcheck.tuple2(commands_gen(), commands_gen()))
  let #(before, after) = pair
  let commands = list.flatten([before, [Deliver(machine.Cast(-1))], after])
  let #(_, stopped) = run(workhorse(), commands)
  assert machine.is_stopped(stopped) as "stopped-machine-stopped"
  let #(effects, continued) =
    run(stopped, [Deliver(machine.Cast(1)), Wait(100)])
  assert effects == [] as "stopped-machine-no-effects"
  assert observe(continued) == observe(stopped) as "stopped-machine-frozen"
}

// ---------------------------------------------------------------------------
// Postpone redelivery: FIFO order, retried after the state change.
// ---------------------------------------------------------------------------

type RPhase {
  RLed
  ROpen
}

type RMsg {
  RGo(n: Int)
  RTap(n: Int)
  RTrigger
}

type REvent {
  RSeenGo(n: Int)
  RSeenTap(n: Int)
}

fn recorder() -> Machine(RPhase, List(REvent), RMsg, Nil) {
  machine.new(phase: RLed, data: [], handler: recorder_handler)
}

fn recorder_handler(
  input: Input(RMsg, Nil),
  phase: RPhase,
  data: List(REvent),
) -> Step(RPhase, List(REvent), RMsg, Nil) {
  case phase, input {
    RLed, machine.Cast(RGo(_)) -> machine.KeepStateAndData([effect.Postpone])
    RLed, machine.Cast(RTap(n)) ->
      machine.KeepState(list.append(data, [RSeenTap(n)]), [])
    RLed, machine.Cast(RTrigger) -> machine.NextState(ROpen, data, [])
    _, machine.Cast(RGo(n)) ->
      machine.KeepState(list.append(data, [RSeenGo(n)]), [])
    _, machine.Cast(RTap(n)) ->
      machine.KeepState(list.append(data, [RSeenTap(n)]), [])
    _, _ -> machine.KeepState(data, [])
  }
}

pub fn postponed_inputs_redeliver_in_fifo_order_test() {
  use ns <- qcheck.given(qcheck.generic_list(
    qcheck.bounded_int(0, 1000),
    qcheck.bounded_int(0, 12),
  ))
  let m =
    list.fold(ns, recorder(), fn(m, n) {
      let #(_, m) = machine.step(m, machine.Cast(RGo(n)))
      m
    })
  let queued = list.map(ns, fn(n) { machine.Cast(RGo(n)) })
  assert machine.postponed_inputs(m) == queued as "postpone-fifo-while-queued"
  let #(_, open) = machine.step(m, machine.Cast(RTrigger))
  assert machine.data(open) == list.map(ns, RSeenGo)
    as "postpone-fifo-after-redelivery"
  assert machine.postponed_inputs(open) == [] as "postpone-fifo-drained"
}

// ---------------------------------------------------------------------------
// Timer scoping laws.
// ---------------------------------------------------------------------------

type TPhase {
  TA
  TB
}

type TMsg {
  TTock
  TArm(ms: Int)
  TArmEvent(ms: Int)
  TArmGeneric(ms: Int)
  TRearm(ms: Int)
  TTouch
  TSwitch
  TTap
}

type TFired {
  FiredState
  FiredEvent
  FiredGeneric
}

fn timer_fixture() -> Machine(TPhase, List(TFired), TMsg, Nil) {
  machine.new(phase: TA, data: [], handler: timer_handler)
}

fn timer_handler(
  input: Input(TMsg, Nil),
  phase: TPhase,
  data: List(TFired),
) -> Step(TPhase, List(TFired), TMsg, Nil) {
  case phase, input {
    _, machine.Timeout(effect.StateTimer, _) ->
      machine.KeepState(list.append(data, [FiredState]), [])
    _, machine.Timeout(effect.EventTimer, _) ->
      machine.KeepState(list.append(data, [FiredEvent]), [])
    _, machine.Timeout(effect.GenericTimer(_), _) ->
      machine.KeepState(list.append(data, [FiredGeneric]), [])
    TA, machine.Cast(TArm(ms)) ->
      machine.KeepStateAndData([effect.StateTimeout(effect.After(ms), TTock)])
    TA, machine.Cast(TArmEvent(ms)) ->
      machine.KeepStateAndData([effect.EventTimeout(effect.After(ms), TTock)])
    TA, machine.Cast(TArmGeneric(ms)) ->
      machine.KeepStateAndData([
        effect.GenericTimeout(effect.timer_id("g"), effect.After(ms), TTock),
      ])
    TA, machine.Cast(TRearm(ms)) ->
      machine.KeepStateAndData([
        effect.StateTimeout(effect.After(ms), TTock),
        effect.StateTimeout(effect.After(ms * 3 + 1), TTock),
      ])
    TA, machine.Cast(TTouch) ->
      machine.KeepStateAndData([effect.UpdateStateTimeout(TTock)])
    TA, machine.Cast(TSwitch) -> machine.NextState(TB, data, [])
    _, _ -> machine.KeepState(data, [])
  }
}

pub fn state_timer_cancelled_by_state_change_test() {
  use ms <- qcheck.given(qcheck.bounded_int(1, 100))
  let #(_, m) = machine.step(timer_fixture(), machine.Cast(TArm(ms)))
  let #(_, m) = machine.step(m, machine.Cast(TSwitch))
  let #(_, m) = machine.advance_time(m, ms + 1000)
  assert machine.data(m) == [] as "state-timer-cancelled"
}

pub fn state_timer_fires_exactly_once_without_change_test() {
  use ms <- qcheck.given(qcheck.bounded_int(1, 100))
  let #(_, m) = machine.step(timer_fixture(), machine.Cast(TArm(ms)))
  let #(_, m) = machine.advance_time(m, ms)
  let #(_, m) = machine.advance_time(m, ms * 10)
  assert machine.data(m) == [FiredState] as "state-timer-fires-once"
}

pub fn event_timer_cancelled_by_any_input_test() {
  use ms <- qcheck.given(qcheck.bounded_int(2, 100))
  let #(_, m) = machine.step(timer_fixture(), machine.Cast(TArmEvent(ms)))
  let #(_, m) = machine.step(m, machine.Cast(TTap))
  let #(_, m) = machine.advance_time(m, ms * 2)
  assert machine.data(m) == [] as "event-timer-cancelled"
}

pub fn event_timer_fires_when_no_input_intervenes_test() {
  use ms <- qcheck.given(qcheck.bounded_int(2, 100))
  let #(_, m) = machine.step(timer_fixture(), machine.Cast(TArmEvent(ms)))
  let #(_, m) = machine.advance_time(m, ms)
  assert machine.data(m) == [FiredEvent] as "event-timer-fires"
}

pub fn generic_timer_survives_state_change_test() {
  use ms <- qcheck.given(qcheck.bounded_int(1, 100))
  let #(_, m) = machine.step(timer_fixture(), machine.Cast(TArmGeneric(ms)))
  let #(_, m) = machine.step(m, machine.Cast(TSwitch))
  let #(_, m) = machine.advance_time(m, ms + 10)
  assert machine.data(m) == [FiredGeneric] as "generic-timer-survives"
}

pub fn rearming_replaces_within_one_transition_test() {
  use ms <- qcheck.given(qcheck.bounded_int(1, 30))
  let #(_, m) = machine.step(timer_fixture(), machine.Cast(TRearm(ms)))
  let #(_, before) = machine.advance_time(m, ms * 3)
  assert machine.data(before) == [] as "rearm-earlier-ignored"
  let #(_, after) = machine.advance_time(before, 1)
  assert machine.data(after) == [FiredState] as "rearm-later-wins"
}

// ---------------------------------------------------------------------------
// Enter callback: fires on begin, on phase change, and on repeat — never on
// keep or on a next-state to the same value. Checked against an independent
// per-op tally.
// ---------------------------------------------------------------------------

type EOp {
  EGoNext
  EGoSame
  EKeep
  ERepeat
  EHalt
}

fn enter_fixture() -> Machine(Int, List(Int), EOp, Nil) {
  machine.new(phase: 0, data: [], handler: enter_handler)
  |> machine.with_state_enter(fn(old, data) {
    EnterKeep(list.append(data, [old]), [])
  })
}

pub fn initial_entry_runs_once_before_the_first_input_test() {
  let #(_, stepped) = machine.step(enter_fixture(), machine.Cast(EGoNext))
  let #(again, stepped) = machine.begin(stepped)
  assert again == []
  assert machine.data(stepped) == [0, 0]
}

pub fn advancing_time_rearms_relative_to_the_end_of_the_jump_test() {
  let timer = effect.StateTimeout(effect.After(5), Nil)
  let clock =
    machine.new(Nil, 0, fn(_, _, fired) {
      machine.KeepState(fired + 1, [timer])
    })
    |> machine.with_state_enter(fn(_, _) {
      machine.EnterKeepData([
        effect.EntryArm(effect.StateTimer, effect.After(5), Nil),
      ])
    })
  let #(_, jumped) = machine.advance_time(clock, 10)
  assert machine.data(jumped) == 1
  assert machine.pending_timeouts(jumped) == [#(effect.StateTimer, 5, Nil)]
}

fn enter_handler(
  input: Input(EOp, Nil),
  phase: Int,
  data: List(Int),
) -> Step(Int, List(Int), EOp, Nil) {
  case input {
    machine.Cast(EGoNext) -> machine.NextState(phase + 1, data, [])
    machine.Cast(EGoSame) -> machine.NextState(phase, data, [])
    machine.Cast(EKeep) -> machine.KeepState(data, [])
    machine.Cast(ERepeat) -> machine.RepeatState(data, [])
    machine.Cast(EHalt) -> machine.Stop(process.Normal)
    machine.Timeout(_, _) -> machine.KeepState(data, [])
    _ -> machine.KeepState(data, [])
  }
}

fn expected_enters(ops: List(EOp)) -> List(Int) {
  let #(entries, _, _) =
    list.fold(ops, #([], 0, False), fn(acc, op) {
      let #(entries, phase, halted) = acc
      case halted {
        True -> acc
        False ->
          case op {
            EGoNext -> #(list.append(entries, [phase]), phase + 1, False)
            EGoSame -> acc
            EKeep -> acc
            ERepeat -> #(list.append(entries, [phase]), phase, False)
            EHalt -> #(entries, phase, True)
          }
      }
    })
  entries
}

pub fn enter_fires_iff_begin_change_or_repeat_test() {
  use ops <- qcheck.given(qcheck.generic_list(
    op_gen(),
    qcheck.bounded_int(0, 14),
  ))
  let #(begin_effects, m) = machine.begin(enter_fixture())
  assert begin_effects == [] as "enter-begin-no-effects"
  let m =
    list.fold(ops, m, fn(m, op) {
      let #(_, m) = machine.step(m, machine.Cast(op))
      m
    })
  assert machine.data(m) == list.append([0], expected_enters(ops))
    as "enter-fires-iff"
}

fn op_gen() -> qcheck.Generator(EOp) {
  qcheck.from_weighted_generators(#(3, qcheck.return(EGoNext)), [
    #(2, qcheck.return(EGoSame)),
    #(2, qcheck.return(EKeep)),
    #(2, qcheck.return(ERepeat)),
    #(1, qcheck.return(EHalt)),
  ])
}

// ---------------------------------------------------------------------------
// Edges: zero-delay arming and updating a timer that is not running both
// deliver immediately, as the newest queued event.
// ---------------------------------------------------------------------------

pub fn zero_delay_state_timer_fires_immediately_test() {
  let #(_, m) = machine.step(timer_fixture(), machine.Cast(TArm(0)))
  let #(_, m) = machine.advance_time(m, 0)
  assert machine.data(m) == [FiredState] as "zero-delay-fires"
}

pub fn update_without_running_timer_fires_immediately_test() {
  let m = timer_fixture()
  let #(_, m) = machine.step(m, machine.Cast(TTouch))
  let #(_, m) = machine.advance_time(m, 0)
  assert machine.data(m) == [FiredState] as "update-not-running-fires"
}

// ---------------------------------------------------------------------------
// Oracle validation: the composition checker must reject a run whose effects
// were tampered with, proving the law can observe effect loss.
// ---------------------------------------------------------------------------

pub fn composition_checker_rejects_lost_effects_test() {
  let commands = [
    Deliver(machine.Call(caller_fixture.token(), 3)),
    Deliver(machine.Cast(3)),
    Deliver(machine.Cast(0)),
    Deliver(machine.Cast(2)),
    Deliver(machine.Cast(4)),
    Wait(60),
  ]
  let #(effects, _) = run(workhorse(), commands)
  let sabotaged = list.take(effects, list.length(effects) - 1)
  case sabotaged == effects {
    True -> panic as "oracle cannot detect effect loss"
    False -> Nil
  }
  let #(prefix_effects, middle) = run(workhorse(), list.take(commands, 2))
  let #(suffix_effects, _) = run(middle, list.drop(commands, 2))
  case list.append(prefix_effects, suffix_effects) == effects {
    True -> Nil
    False -> panic as "composition oracle disagrees with an honest run"
  }
}
