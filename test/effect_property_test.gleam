////
//// Laws of the effect algebra (`eparch/effect`), checked with generated
//// effect lists. Reply effects use a token from a real OTP call.
////

import caller_fixture
import eparch/effect.{type Effect}
import gleam/int
import gleam/list
import qcheck

fn timeout_time_gen() -> qcheck.Generator(effect.TimeoutTime) {
  qcheck.from_weighted_generators(
    #(4, qcheck.map(qcheck.bounded_int(0, 100), effect.After)),
    [#(1, qcheck.map(qcheck.bounded_int(0, 200), effect.At))],
  )
}

fn timer_id_gen() -> qcheck.Generator(effect.TimerId) {
  qcheck.map(qcheck.bounded_int(0, 3), fn(i) {
    effect.timer_id(int.to_string(i))
  })
}

fn effect_gen() -> qcheck.Generator(Effect(Int, Int)) {
  let msg = qcheck.bounded_int(0, 50)
  let reply = qcheck.bounded_int(0, 50)
  let from = caller_fixture.token()
  qcheck.from_weighted_generators(
    #(3, qcheck.map(reply, effect.Reply(from, _))),
    [
      #(1, qcheck.return(effect.Postpone)),
      #(
        2,
        qcheck.map2(msg, msg, fn(content, extra) {
          effect.NextEvent(next_kind_gen_value(extra, from), content)
        }),
      ),
      #(4, qcheck.map2(timeout_time_gen(), msg, effect.StateTimeout)),
      #(4, qcheck.map2(timeout_time_gen(), msg, effect.EventTimeout)),
      #(
        5,
        qcheck.map3(
          timer_id_gen(),
          timeout_time_gen(),
          msg,
          effect.GenericTimeout,
        ),
      ),
      #(2, qcheck.return(effect.CancelStateTimeout)),
      #(2, qcheck.return(effect.CancelEventTimeout)),
      #(2, qcheck.map(timer_id_gen(), effect.CancelGenericTimeout)),
      #(2, qcheck.map(msg, effect.UpdateStateTimeout)),
      #(2, qcheck.map(msg, effect.UpdateEventTimeout)),
      #(3, qcheck.map2(timer_id_gen(), msg, effect.UpdateGenericTimeout)),
      #(1, qcheck.return(effect.Hibernate)),
    ],
  )
}

fn next_kind_gen_value(
  i: Int,
  from: effect.From(Int),
) -> effect.NextEventKind(Int) {
  case i % 4 {
    0 -> effect.InternalEvent
    1 -> effect.CastEvent
    2 -> effect.InfoEvent
    _ -> effect.CallEvent(from)
  }
}

fn effects_gen() -> qcheck.Generator(List(Effect(Int, Int))) {
  qcheck.generic_list(effect_gen(), qcheck.bounded_int(0, 16))
}

pub fn resolution_preserves_the_order_and_multiplicity_of_non_timer_effects_test() {
  use effects <- qcheck.given(effects_gen())
  let non_timer = fn(e) { class_of(e) == "other" }
  assert list.filter(effect.resolve(effects), non_timer)
    == list.filter(effects, non_timer)
}

pub fn resolve_is_idempotent_test() {
  use es <- qcheck.given(effects_gen())
  assert effect.resolve(effect.resolve(es)) == effect.resolve(es)
    as "resolve-idempotent"
}

pub fn resolve_composes_over_append_test() {
  use pair <- qcheck.given(qcheck.tuple2(effects_gen(), effects_gen()))
  let #(a, b) = pair
  assert effect.resolve(list.append(a, b))
    == effect.resolve(list.append(effect.resolve(a), effect.resolve(b)))
    as "resolve-composition"
}

/// After resolution at most one decision per timer class survives, in the
/// position of the last decision.
///
pub fn resolve_keeps_one_decision_per_timer_class_test() {
  use es <- qcheck.given(effects_gen())
  let resolved = effect.resolve(es)
  assert deciding_classes(resolved) == dedupe(deciding_classes(resolved))
    as "resolve-one-per-class"
}

/// The surviving decision per class is the last one from the input list.
///
pub fn resolve_keeps_the_last_decision_per_class_test() {
  use es <- qcheck.given(effects_gen())
  let resolved = effect.resolve(es)
  assert list.all(class_keys(es), fn(key) {
    last_effect_of_class(es, key) == first_effect_of_class(resolved, key)
  })
    as "resolve-last-wins"
}

// --- helpers ------------------------------------------------------------

fn deciding_classes(effects: List(Effect(Int, Int))) -> List(String) {
  list.filter_map(effects, fn(e) {
    case class_of(e) {
      "other" -> Error(Nil)
      key -> Ok(key)
    }
  })
}

fn class_keys(effects: List(Effect(Int, Int))) -> List(String) {
  dedupe(deciding_classes(effects))
}

fn last_effect_of_class(
  effects: List(Effect(Int, Int)),
  key: String,
) -> Result(Effect(Int, Int), Nil) {
  list.fold_until(effects, Error(Nil), fn(acc, e) {
    case class_of(e) == key {
      True -> list.Continue(Ok(e))
      False -> list.Continue(acc)
    }
  })
}

fn first_effect_of_class(
  effects: List(Effect(Int, Int)),
  key: String,
) -> Result(Effect(Int, Int), Nil) {
  list.find(effects, fn(e) { class_of(e) == key })
}

fn class_of(e: Effect(Int, Int)) -> String {
  case e {
    effect.StateTimeout(..)
    | effect.CancelStateTimeout
    | effect.UpdateStateTimeout(_) -> "state"
    effect.EventTimeout(..)
    | effect.CancelEventTimeout
    | effect.UpdateEventTimeout(_) -> "event"
    effect.GenericTimeout(id, ..)
    | effect.CancelGenericTimeout(id)
    | effect.UpdateGenericTimeout(id, _) ->
      "generic:" <> effect.timer_id_to_string(id)
    _ -> "other"
  }
}

fn dedupe(keys: List(String)) -> List(String) {
  list.fold(keys, [], fn(seen, key) {
    case list.contains(seen, key) {
      True -> seen
      False -> list.append(seen, [key])
    }
  })
}

fn timer_kind_gen() -> qcheck.Generator(effect.TimerKind) {
  qcheck.from_generators(qcheck.return(effect.StateTimer), [
    qcheck.return(effect.EventTimer),
    qcheck.map(timer_id_gen(), effect.GenericTimer),
  ])
}

fn entry_effect_gen() -> qcheck.Generator(effect.EntryEffect(Int, Int)) {
  let msg = qcheck.bounded_int(0, 50)
  let from = caller_fixture.token()
  qcheck.from_generators(qcheck.map(msg, effect.EntryReply(from, _)), [
    qcheck.map3(timer_kind_gen(), timeout_time_gen(), msg, effect.EntryArm),
    qcheck.map(timer_kind_gen(), effect.EntryCancel),
    qcheck.map2(timer_kind_gen(), msg, effect.EntryUpdate),
    qcheck.return(effect.EntryHibernate),
  ])
}

fn entry_kind(
  entry: effect.EntryEffect(Int, Int),
) -> Result(effect.TimerKind, Nil) {
  case entry {
    effect.EntryArm(kind, _, _)
    | effect.EntryCancel(kind)
    | effect.EntryUpdate(kind, _) -> Ok(kind)
    effect.EntryReply(_, _) | effect.EntryHibernate -> Error(Nil)
  }
}

/// `from_entry` is an embedding of the entry vocabulary: every timer
/// decision keeps its class, and nothing else decides a timer.
pub fn from_entry_preserves_the_timer_class_test() {
  use #(entry, kind) <- qcheck.given(qcheck.tuple2(
    entry_effect_gen(),
    timer_kind_gen(),
  ))
  let embedded = effect.from_entry(entry)
  assert effect.decides_timer(embedded, kind)
    == { entry_kind(entry) == Ok(kind) }
}

/// Embedding commutes with resolution: resolving entry effects after
/// embedding them keeps exactly one decision per timer class, the last.
pub fn from_entry_commutes_with_resolution_test() {
  use entries <- qcheck.given(qcheck.generic_list(
    entry_effect_gen(),
    qcheck.bounded_int(0, 10),
  ))
  let embedded = list.map(entries, effect.from_entry)
  assert effect.resolve(embedded) == effect.resolve(effect.resolve(embedded))
  assert list.length(effect.resolve(embedded)) <= list.length(embedded)
}

/// A relative deadline never lies in the past, whatever the delay's sign,
/// and an absolute deadline ignores the clock.
pub fn deadlines_are_monotone_in_the_clock_test() {
  use #(clock, delay, other_clock) <- qcheck.given(qcheck.tuple3(
    qcheck.bounded_int(-1000, 1000),
    qcheck.bounded_int(-100, 100),
    qcheck.bounded_int(-1000, 1000),
  ))
  assert effect.deadline_from(clock, effect.After(delay)) >= clock
  assert effect.deadline_from(clock, effect.After(delay))
    == clock + int.max(0, delay)
  assert effect.deadline_from(clock, effect.At(delay))
    == effect.deadline_from(other_clock, effect.At(delay))
}
