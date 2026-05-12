////
//// Integration tests for the pushbutton state machine.
////
//// These tests spawn a real gen_statem process and exercise it through the
//// public API (`push` / `get_count`). They verify observable behaviour
//// rather than direct handler output.
////

import eparch/state_machine as sm
import gleeunit/should
import pushbutton

fn start() -> sm.ServerRef(pushbutton.Message) {
  let assert Ok(machine) = pushbutton.start()
  machine.ref
}

/// A freshly started pushbutton has count 0.
pub fn initial_count_is_zero_test() {
  let ref = start()
  pushbutton.get_count(ref) |> should.equal(0)
}

/// Pushing from Off transitions to On, increments the count, and replies On.
pub fn push_when_off_replies_on_and_increments_test() {
  let ref = start()

  pushbutton.push(ref) |> should.equal(pushbutton.On)
  pushbutton.get_count(ref) |> should.equal(1)
}

/// Pushing from On transitions back to Off without changing the count.
pub fn push_when_on_replies_off_without_incrementing_test() {
  let ref = start()

  pushbutton.push(ref) |> should.equal(pushbutton.On)
  pushbutton.push(ref) |> should.equal(pushbutton.Off)
  pushbutton.get_count(ref) |> should.equal(1)
}

/// The press count equals the number of completed Off -> On transitions.
pub fn count_equals_number_of_on_cycles_test() {
  let ref = start()

  pushbutton.push(ref)
  pushbutton.push(ref)
  pushbutton.push(ref)
  pushbutton.push(ref)
  pushbutton.push(ref)
  pushbutton.push(ref)
  pushbutton.push(ref)
  pushbutton.push(ref)
  pushbutton.push(ref)
  pushbutton.push(ref)

  pushbutton.get_count(ref) |> should.equal(5)
}

/// GetCount works in both Off and On states and does not mutate the count.
pub fn get_count_is_state_agnostic_test() {
  let ref = start()

  // In Off state.
  pushbutton.get_count(ref) |> should.equal(0)

  // Push to On and query again.
  pushbutton.push(ref)
  pushbutton.get_count(ref) |> should.equal(1)
  pushbutton.get_count(ref) |> should.equal(1)
}

/// Casts are silently ignored: the wildcard branch keeps state and data.
/// A cast of `Push` must NOT increment the count or transition to On.
pub fn cast_is_silently_ignored_test() {
  let ref = start()

  sm.cast(ref, pushbutton.Push)

  pushbutton.get_count(ref) |> should.equal(0)
}
