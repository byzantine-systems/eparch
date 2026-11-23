////
//// Homomorphism law between the two interpreters of one transition algebra,
//// checked over generated scripts from the shared workload in
//// `dev/eparch/workload/statem`, plus the minimised counterexamples it has
//// found.
////

import eparch/workload/statem.{
  ArmNow, Change, Differential, EventKind, Keep, PostponeThis, Run, StateKind,
  Update,
}
import gleam/list
import qcheck

pub fn otp_interprets_every_effect_list_like_the_logical_machine_test() {
  use script <- qcheck.run(
    qcheck.default_config() |> qcheck.with_test_count(150),
    statem.script_gen(),
  )
  let Differential(otp, model) = statem.differential(script)
  assert otp == Ok(model)
}

/// Minimised counterexample the law found: a pending zero *state* timeout
/// must not suppress a zero *event* timeout requested after it, because
/// gen_statem queues zero timeouts separately from inserted and postponed
/// events.
pub fn pending_zero_timeouts_do_not_suppress_a_zero_event_timeout_test() {
  let Differential(otp, model) =
    statem.differential([
      Run(Keep, [ArmNow(EventKind, 0), ArmNow(StateKind, 0), PostponeThis]),
      Run(Change, [Update(StateKind, 0)]),
    ])
  assert list.contains(model, "event:0")
  assert otp == Ok(model)
}
