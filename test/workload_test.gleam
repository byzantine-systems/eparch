////
//// The Antithesis workload scenarios, run as ordinary properties: every
//// `Always` verdict must hold for generated inputs, and each `Sometimes`
//// verdict must be witnessed by at least one run. Antithesis replays the
//// same scenarios under scheduler perturbation and faults.
////

import eparch/workload/broadcast
import eparch/workload/cluster
import eparch/workload/statem
import eparch/workload/verdict
import gleam/list
import qcheck

fn witnessed(runs: List(List(verdict.Verdict)), message: String) -> Bool {
  list.any(runs, fn(verdicts) {
    list.any(verdicts, fn(v) { v.message == message && v.holds })
  })
}

pub fn broadcast_always_verdicts_hold_test() {
  use #(burst, kill) <- qcheck.run(
    qcheck.default_config() |> qcheck.with_test_count(20),
    qcheck.tuple2(qcheck.bounded_int(1, 16), qcheck.bool()),
  )
  let mode = case kill {
    True -> broadcast.Kill
    False -> broadcast.Normal
  }
  let verdicts = broadcast.verdicts(broadcast.run(burst, mode))
  assert verdict.violations(verdicts) == []
}

pub fn broadcast_sometimes_verdicts_are_reachable_test() {
  let runs = [
    broadcast.verdicts(broadcast.run(8, broadcast.Normal)),
    broadcast.verdicts(broadcast.run(8, broadcast.Kill)),
  ]
  assert witnessed(runs, "A saturated manager accepts a later fence")
  assert witnessed(
    runs,
    "An outstanding confirmation observes the manager's death",
  )
}

pub fn statem_always_verdicts_hold_test() {
  use seed <- qcheck.run(
    qcheck.default_config() |> qcheck.with_test_count(30),
    qcheck.bounded_int(0, 1_000_000),
  )
  assert verdict.violations(statem.verdicts(statem.run(seed))) == []
}

pub fn statem_sometimes_verdicts_are_reachable_test() {
  let runs =
    list.map([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], fn(seed) {
      statem.verdicts(statem.run(seed))
    })
  assert witnessed(runs, "A generated script fires a zero event timeout")
}

pub fn cluster_always_verdicts_hold_test() {
  use seed <- qcheck.run(
    qcheck.default_config() |> qcheck.with_test_count(5),
    qcheck.bounded_int(0, 1_000_000),
  )
  assert verdict.violations(cluster.verdicts(cluster.run(seed))) == []
}

pub fn cluster_sometimes_verdicts_are_reachable_test() {
  // Seeds 2 and 10 together witness every cluster `sometimes` claim.
  let runs = list.map([2, 10], fn(seed) { cluster.verdicts(cluster.run(seed)) })
  assert witnessed(runs, "A cross-node call succeeds")
  assert witnessed(runs, "A cross-node call times out")
  assert witnessed(runs, "A call to an isolated node's global server fails")
  assert witnessed(runs, "A reachable remote manager confirms a publication")
  assert witnessed(runs, "A live but unreachable manager is reported down")
}
