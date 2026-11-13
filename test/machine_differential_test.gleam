////
//// Homomorphism law between the two interpreters of one transition algebra:
//// for every generated script, `eparch/machine` (the reference model) and
//// `eparch/machine/otp` on a real `gen_statem` (the implementation) deliver
//// the same trace of handled inputs.
////
//// Scripts draw on the whole effect vocabulary that is observable without a
//// wall clock: zero-delay and far-future timers of every class, cancels and
//// updates (including of timers that are not running), inserted events of
//// each kind, postponement, state changes, and repeated entry. Far-future
//// timers never fire during a run, so they only matter through the
//// cancel/update interactions they enable, which keeps the law
//// deterministic. Wall-clock firing stays covered by examples in
//// `actions_test`.
////

import caller_fixture
import eparch/effect
import eparch/machine
import eparch/machine/otp
import eparch/state_machine
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{Some}
import qcheck

const far_future = 3_600_000

type Kind {
  StateKind
  EventKind
  GenericKind(slot: Int)
}

type Insertion {
  InsertInternal
  InsertCast
  InsertInfo
}

type Op {
  ArmNow(kind: Kind, mark: Int)
  ArmLater(kind: Kind, mark: Int)
  Cancel(kind: Kind)
  Update(kind: Kind, mark: Int)
  Insert(kind: Insertion, mark: Int)
  /// Insert an event that is itself a transition, so effects can act on
  /// timers and events queued by the enclosing transition.
  InsertRun(kind: Insertion, transition: Transition, ops: List(Op))
  PostponeThis
}

type Transition {
  Keep
  Change
  Reenter
}

type Msg {
  Run(transition: Transition, ops: List(Op))
  Mark(Int)
  Snapshot
}

fn timer_kind(kind: Kind) -> effect.TimerKind {
  case kind {
    StateKind -> effect.StateTimer
    EventKind -> effect.EventTimer
    GenericKind(slot) -> effect.GenericTimer(generic_id(slot))
  }
}

fn generic_id(slot: Int) -> effect.TimerId {
  effect.timer_id(int.to_string(slot))
}

fn op_effect(op: Op) -> effect.Effect(Msg, List(String)) {
  case op {
    ArmNow(kind, mark) -> arm(kind, effect.After(0), mark)
    ArmLater(kind, mark) -> arm(kind, effect.After(far_future), mark)
    Cancel(StateKind) -> effect.CancelStateTimeout
    Cancel(EventKind) -> effect.CancelEventTimeout
    Cancel(GenericKind(slot)) -> effect.CancelGenericTimeout(generic_id(slot))
    Update(StateKind, mark) -> effect.UpdateStateTimeout(Mark(mark))
    Update(EventKind, mark) -> effect.UpdateEventTimeout(Mark(mark))
    Update(GenericKind(slot), mark) ->
      effect.UpdateGenericTimeout(generic_id(slot), Mark(mark))
    Insert(InsertInternal, mark) ->
      effect.NextEvent(effect.InternalEvent, Mark(mark))
    Insert(InsertCast, mark) -> effect.NextEvent(effect.CastEvent, Mark(mark))
    Insert(InsertInfo, mark) -> effect.NextEvent(effect.InfoEvent, Mark(mark))
    InsertRun(kind, transition, ops) ->
      effect.NextEvent(insertion(kind), Run(transition, ops))
    PostponeThis -> effect.Postpone
  }
}

fn arm(
  kind: Kind,
  time: effect.TimeoutTime,
  mark: Int,
) -> effect.Effect(Msg, List(String)) {
  case timer_kind(kind) {
    effect.StateTimer -> effect.StateTimeout(time, Mark(mark))
    effect.EventTimer -> effect.EventTimeout(time, Mark(mark))
    effect.GenericTimer(id) -> effect.GenericTimeout(id, time, Mark(mark))
  }
}

fn insertion(kind: Insertion) -> effect.NextEventKind(List(String)) {
  case kind {
    InsertInternal -> effect.InternalEvent
    InsertCast -> effect.CastEvent
    InsertInfo -> effect.InfoEvent
  }
}

fn timer_label(kind: effect.TimerKind) -> String {
  case kind {
    effect.StateTimer -> "state"
    effect.EventTimer -> "event"
    effect.GenericTimer(id) -> "generic" <> effect.timer_id_to_string(id)
  }
}

fn handle(
  input: machine.Input(Msg, List(String)),
  phase: Bool,
  trace: List(String),
) -> machine.Step(Bool, List(String), Msg, List(String)) {
  case input {
    machine.Cast(Run(transition, ops)) ->
      run(phase, trace, "cast", transition, ops)
    machine.Info(Run(transition, ops)) ->
      run(phase, trace, "info", transition, ops)
    machine.Internal(Run(transition, ops)) ->
      run(phase, trace, "internal", transition, ops)
    machine.Call(from, Snapshot) ->
      machine.StopAndReply(process.Normal, [#(from, list.reverse(trace))])
    machine.Cast(Mark(n)) -> record(trace, "cast", n)
    machine.Info(Mark(n)) -> record(trace, "info", n)
    machine.Internal(Mark(n)) -> record(trace, "internal", n)
    machine.Timeout(kind, Mark(n)) -> record(trace, timer_label(kind), n)
    machine.Timeout(_, _)
    | machine.Cast(Snapshot)
    | machine.Info(Snapshot)
    | machine.Internal(Snapshot)
    | machine.Call(_, _) -> machine.KeepState(["other", ..trace], [])
  }
}

fn run(
  phase: Bool,
  trace: List(String),
  label: String,
  transition: Transition,
  ops: List(Op),
) -> machine.Step(Bool, List(String), Msg, List(String)) {
  let effects = list.map(ops, op_effect)
  let trace = ["run:" <> label, ..trace]
  case transition {
    Keep -> machine.KeepState(trace, effects)
    Change -> machine.NextState(!phase, trace, effects)
    Reenter -> machine.RepeatState(trace, effects)
  }
}

fn record(
  trace: List(String),
  label: String,
  n: Int,
) -> machine.Step(Bool, List(String), Msg, List(String)) {
  machine.KeepState([label <> ":" <> int.to_string(n), ..trace], [])
}

fn enter(
  _old: Bool,
  trace: List(String),
) -> machine.EnterStep(List(String), Msg, List(String)) {
  machine.EnterKeep(["enter", ..trace], [])
}

fn kind_gen() -> qcheck.Generator(Kind) {
  qcheck.from_generators(qcheck.return(StateKind), [
    qcheck.return(EventKind),
    qcheck.map(qcheck.bounded_int(0, 1), GenericKind),
  ])
}

fn mark_gen() -> qcheck.Generator(Int) {
  qcheck.bounded_int(0, 9)
}

fn insertion_gen() -> qcheck.Generator(Insertion) {
  qcheck.from_generators(qcheck.return(InsertInternal), [
    qcheck.return(InsertCast),
    qcheck.return(InsertInfo),
  ])
}

fn op_gen() -> qcheck.Generator(Op) {
  qcheck.from_weighted_generators(#(12, leaf_op_gen()), [
    #(
      2,
      qcheck.map2(
        insertion_gen(),
        transition_ops_gen(leaf_op_gen()),
        fn(kind, pair) {
          let #(transition, ops) = pair
          InsertRun(kind, transition, ops)
        },
      ),
    ),
  ])
}

fn leaf_op_gen() -> qcheck.Generator(Op) {
  qcheck.from_weighted_generators(
    #(3, qcheck.map2(kind_gen(), mark_gen(), ArmNow)),
    [
      #(2, qcheck.map2(kind_gen(), mark_gen(), ArmLater)),
      #(2, qcheck.map(kind_gen(), Cancel)),
      #(2, qcheck.map2(kind_gen(), mark_gen(), Update)),
      #(2, qcheck.map2(insertion_gen(), mark_gen(), Insert)),
    ],
  )
}

/// Postponing a transition that also changes state would retry itself
/// forever, so `Postpone` is only generated for `Keep` transitions whose
/// inserted runs do not change state either.
fn transition_ops_gen(
  ops: qcheck.Generator(Op),
) -> qcheck.Generator(#(Transition, List(Op))) {
  use transition, ops, postpone <- qcheck.map3(
    qcheck.from_weighted_generators(#(3, qcheck.return(Keep)), [
      #(2, qcheck.return(Change)),
      #(1, qcheck.return(Reenter)),
    ]),
    qcheck.generic_list(ops, qcheck.bounded_int(0, 4)),
    qcheck.bool(),
  )
  case transition, postpone {
    Keep, True -> #(
      Keep,
      list.append(list.map(ops, without_state_change), [PostponeThis]),
    )
    Keep, False | Change, _ | Reenter, _ -> #(transition, ops)
  }
}

/// A postponed input is retried after every state change, so a postponing
/// run must not cause one, not even through an inserted run.
fn without_state_change(op: Op) -> Op {
  case op {
    InsertRun(kind, Change, ops) -> InsertRun(kind, Reenter, ops)
    InsertRun(_, Keep, _)
    | InsertRun(_, Reenter, _)
    | ArmNow(..)
    | ArmLater(..)
    | Cancel(..)
    | Update(..)
    | Insert(..)
    | PostponeThis -> op
  }
}

fn run_gen() -> qcheck.Generator(Msg) {
  use #(transition, ops) <- qcheck.map(transition_ops_gen(op_gen()))
  Run(transition, ops)
}

pub fn otp_interprets_every_effect_list_like_the_logical_machine_test() {
  use script <- qcheck.run(
    qcheck.default_config() |> qcheck.with_test_count(150),
    qcheck.generic_list(run_gen(), qcheck.bounded_int(0, 8)),
  )
  let assert Ok(server) =
    otp.builder(phase: False, data: [], handler: handle, on_enter: Some(enter))
    |> state_machine.start
  let #(_, model) =
    machine.new(phase: False, data: [], handler: handle)
    |> machine.with_state_enter(enter)
    |> machine.begin
  let model =
    list.fold(script, model, fn(model, message) {
      state_machine.cast(server.ref, message)
      let #(_, next) = machine.step(model, machine.Cast(message))
      next
    })
  let from = caller_fixture.token_for([])
  let #(effects, _) = machine.step(model, machine.Call(from, Snapshot))
  let assert [effect.Reply(_, expected)] = effects
  // Same-sender ordering makes this call a fence after the external casts.
  assert state_machine.call(server.ref, Snapshot, waiting: 1000) == Ok(expected)
}

/// Minimised counterexample the law found: a pending zero *state* timeout
/// must not suppress a zero *event* timeout requested after it, because
/// gen_statem queues zero timeouts separately from inserted and postponed
/// events.
pub fn pending_zero_timeouts_do_not_suppress_a_zero_event_timeout_test() {
  let script = [
    Run(Keep, [ArmNow(EventKind, 0), ArmNow(StateKind, 0), PostponeThis]),
    Run(Change, [Update(StateKind, 0)]),
  ]
  let assert Ok(server) =
    otp.builder(phase: False, data: [], handler: handle, on_enter: Some(enter))
    |> state_machine.start
  let #(_, model) =
    machine.new(phase: False, data: [], handler: handle)
    |> machine.with_state_enter(enter)
    |> machine.begin
  let model =
    list.fold(script, model, fn(model, message) {
      state_machine.cast(server.ref, message)
      machine.step(model, machine.Cast(message)).1
    })
  let #(effects, _) =
    machine.step(model, machine.Call(caller_fixture.token_for([]), Snapshot))
  let assert [effect.Reply(_, expected)] = effects
  assert list.contains(expected, "event:0")
  assert state_machine.call(server.ref, Snapshot, waiting: 1000) == Ok(expected)
}
