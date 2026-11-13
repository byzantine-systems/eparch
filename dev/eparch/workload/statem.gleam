//// Interpreter workload: one transition algebra, two interpreters.
////
//// For a generated script, `eparch/machine` (the reference model) and
//// `eparch/machine/otp` on a real `gen_statem` (the implementation) must
//// deliver the same trace of handled inputs. Scripts draw on the whole
//// effect vocabulary that is observable without a wall clock: zero-delay
//// and far-future timers of every class, cancels and updates (including of
//// timers that are not running), inserted events of each kind including
//// nested transitions, postponement, state changes, and re-entry.
//// Far-future timers never fire during a run, so they only matter through
//// the cancel/update interactions they enable, which keeps the comparison
//// deterministic.
////
//// The same module also checks postponed redelivery order and the
//// failed-start acknowledgement flush on a raw `state_machine`. It is
//// shared by `gleam test` and the Antithesis driver.

import eparch/effect
import eparch/machine
import eparch/machine/otp
import eparch/start_options
import eparch/state_machine
import eparch/workload/verdict.{type Verdict}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/string
import qcheck

const far_future = 3_600_000

pub type Kind {
  StateKind
  EventKind
  GenericKind(slot: Int)
}

pub type Insertion {
  InsertInternal
  InsertCast
  InsertInfo
}

pub type Op {
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

pub type Transition {
  Keep
  Change
  Reenter
}

pub type Msg {
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
      run_transition(phase, trace, "cast", transition, ops)
    machine.Info(Run(transition, ops)) ->
      run_transition(phase, trace, "info", transition, ops)
    machine.Internal(Run(transition, ops)) ->
      run_transition(phase, trace, "internal", transition, ops)
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

fn run_transition(
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

/// Generated scripts: up to eight top-level transitions.
pub fn script_gen() -> qcheck.Generator(List(Msg)) {
  qcheck.generic_list(run_gen(), qcheck.bounded_int(0, 8))
}

/// Both interpreters' traces for one script. `otp` is the reply to the
/// snapshot call; `model` is the logical machine's trace in handling order.
pub type Differential {
  Differential(
    otp: Result(List(String), state_machine.ReceiveError),
    model: List(String),
  )
}

pub fn differential(script: List(Msg)) -> Differential {
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
  // Same-sender ordering makes this call a fence after the external casts.
  Differential(
    otp: state_machine.call(server.ref, Snapshot, waiting: 10_000),
    model: list.reverse(machine.data(model)),
  )
}

type FifoMsg {
  Item(Int)
  Open
  Dump
}

/// Postpone `count` items while closed, open, and return the order in which
/// gen_statem redelivered them.
pub fn postponed_order(count: Int) -> List(Int) {
  let assert Ok(server) =
    state_machine.new(initial_state: False, initial_data: [])
    |> state_machine.on_event(fn(event, open, seen) {
      case event, open {
        state_machine.Cast(Item(_)), False ->
          state_machine.keep_state_and_data([state_machine.Postpone])
        state_machine.Cast(Item(n)), True ->
          state_machine.keep_state([n, ..seen], [])
        state_machine.Cast(Open), _ -> state_machine.next_state(True, seen, [])
        state_machine.Call(from, Dump), _ ->
          state_machine.stop_and_reply(process.Normal, [
            #(from, list.reverse(seen)),
          ])
        _, _ -> state_machine.keep_state_and_data([])
      }
    })
    |> state_machine.start
  list.each(ascending(count), fn(n) { state_machine.cast(server.ref, Item(n)) })
  state_machine.cast(server.ref, Open)
  case state_machine.call(server.ref, Dump, waiting: 10_000) {
    Ok(order) -> order
    Error(_) -> []
  }
}

@external(erlang, "eparch_workload_ffi", "mailbox_length")
fn mailbox_length() -> Int

/// Start `attempts` machines with a 0 or 1 ms initialisation timeout from a
/// fresh caller. Returns how many timed out and how many messages were left
/// in that caller's mailbox, which must be none.
pub fn failed_starts(attempts: Int) -> #(Int, Int) {
  let outcome = process.new_subject()
  let _ =
    process.spawn(fn() { process.send(outcome, start_repeatedly(attempts)) })
  let assert Ok(result) = process.receive(outcome, 60_000)
  result
}

fn start_repeatedly(attempts: Int) -> #(Int, Int) {
  let timed_out =
    int.range(from: 0, to: attempts, with: 0, run: fn(timed_out, attempt) {
      let result =
        state_machine.new(initial_state: Nil, initial_data: Nil)
        |> state_machine.with_timeout(start_options.Milliseconds(attempt % 2))
        |> state_machine.start
      case result {
        Error(state_machine.InitTimeout) -> timed_out + 1
        Ok(started) -> {
          let _ = state_machine.stop_server(started.ref)
          timed_out
        }
        Error(_) -> timed_out
      }
    })
  #(timed_out, mailbox_length())
}

pub type Report {
  Report(
    seed: Int,
    script: List(Msg),
    differential: Differential,
    postponed: List(Int),
    expected_postponed: List(Int),
    timed_out_starts: Int,
    leftover_messages: Int,
  )
}

/// Run every interpreter scenario for one seed.
pub fn run(seed: Int) -> Report {
  let #(scripts, _) = qcheck.generate(script_gen(), 1, qcheck.seed(seed))
  let script = case scripts {
    [script, ..] -> script
    [] -> []
  }
  let count = 1 + int.absolute_value(seed) % 8
  let #(timed_out, leftover) = failed_starts(20)
  Report(
    seed:,
    script:,
    differential: differential(script),
    postponed: postponed_order(count),
    expected_postponed: ascending(count),
    timed_out_starts: timed_out,
    leftover_messages: leftover,
  )
}

fn ascending(count: Int) -> List(Int) {
  int.range(from: count, to: 0, with: [], run: fn(acc, n) { [n, ..acc] })
}

pub fn verdicts(report: Report) -> List(Verdict) {
  let details = string.inspect(report)
  let Differential(otp_trace, model_trace) = report.differential
  [
    verdict.always(
      otp_trace == Ok(model_trace),
      "gen_statem and the logical machine deliver the same trace",
      details,
    ),
    verdict.sometimes(
      list.any(model_trace, string.starts_with(_, "event:")),
      "A generated script fires a zero event timeout",
      details,
    ),
    verdict.always(
      report.postponed == report.expected_postponed,
      "Postponed inputs are redelivered oldest first on gen_statem",
      details,
    ),
    verdict.always(
      report.leftover_messages == 0,
      "Failed starts leave the caller's mailbox empty",
      details,
    ),
    verdict.sometimes(
      report.timed_out_starts > 0,
      "A start times out during initialisation",
      details,
    ),
  ]
}
