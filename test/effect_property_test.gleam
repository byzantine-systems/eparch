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
  assert_true(
    effect.resolve(effect.resolve(es)) == effect.resolve(es),
    "resolve-idempotent",
  )
}

pub fn resolve_composes_over_append_test() {
  use pair <- qcheck.given(qcheck.tuple2(effects_gen(), effects_gen()))
  let #(a, b) = pair
  assert_true(
    effect.resolve(list.append(a, b))
      == effect.resolve(list.append(effect.resolve(a), effect.resolve(b))),
    "resolve-composition",
  )
}

/// After resolution at most one decision per timer class survives, in the
/// position of the last decision.
///
pub fn resolve_keeps_one_decision_per_timer_class_test() {
  use es <- qcheck.given(effects_gen())
  let resolved = effect.resolve(es)
  assert_true(
    deciding_classes(resolved) == dedupe(deciding_classes(resolved)),
    "resolve-one-per-class",
  )
}

/// The surviving decision per class is the last one from the input list.
///
pub fn resolve_keeps_the_last_decision_per_class_test() {
  use es <- qcheck.given(effects_gen())
  let resolved = effect.resolve(es)
  assert_true(
    list.all(class_keys(es), fn(key) {
      last_effect_of_class(es, key) == first_effect_of_class(resolved, key)
    }),
    "resolve-last-wins",
  )
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
      "generic:" <> effect.timer_id_name(id)
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

fn assert_true(condition: Bool, label: String) {
  case condition {
    True -> Nil
    False -> panic as { "law violated: " <> label }
  }
}
