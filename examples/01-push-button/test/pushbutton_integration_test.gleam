////
//// Integration tests for the pushbutton state machine.
////
//// These tests spawn a real gen_statem process and exercise it through the
//// public API (`push` / `get_count`). They verify observable behaviour
//// rather than direct handler output.
////

import eparch/state_machine as sm
import gleam/erlang/process
import gleeunit/should
import pushbutton

fn start() -> process.Subject(pushbutton.Msg) {
  let assert Ok(machine) = pushbutton.start()
  machine.data
}

/// A freshly started pushbutton has count 0.
pub fn initial_count_is_zero_test() {
  let subject = start()
  pushbutton.get_count(subject) |> should.equal(0)
}

/// Pushing from Off replies 0 (count before increment) and bumps count to 1.
pub fn push_when_off_replies_zero_and_increments_test() {
  let subject = start()

  pushbutton.push(subject) |> should.equal(0)
  pushbutton.get_count(subject) |> should.equal(1)
}

/// Pushing from On replies the current count without changing it.
pub fn push_when_on_replies_count_without_incrementing_test() {
  let subject = start()

  // Off -> On, count = 1
  pushbutton.push(subject) |> should.equal(0)
  // On -> Off, count stays 1, reply is the current count (1)
  pushbutton.push(subject) |> should.equal(1)
  pushbutton.get_count(subject) |> should.equal(1)
}

/// The press count equals the number of completed Off -> On transitions.
pub fn count_equals_number_of_on_cycles_test() {
  let subject = start()

  // 5 full cycles = 5 Off->On transitions.
  pushbutton.push(subject)
  pushbutton.push(subject)
  pushbutton.push(subject)
  pushbutton.push(subject)
  pushbutton.push(subject)
  pushbutton.push(subject)
  pushbutton.push(subject)
  pushbutton.push(subject)
  pushbutton.push(subject)
  pushbutton.push(subject)

  pushbutton.get_count(subject) |> should.equal(5)
}

/// GetCount works in both Off and On states and does not mutate the count.
pub fn get_count_is_state_agnostic_test() {
  let subject = start()

  // In Off state.
  pushbutton.get_count(subject) |> should.equal(0)

  // Push to On and query again.
  pushbutton.push(subject)
  pushbutton.get_count(subject) |> should.equal(1)
  pushbutton.get_count(subject) |> should.equal(1)
}

/// Casts are ignored: the handler only responds to synchronous calls.
/// Sending a cast must leave the count untouched and produce no reply.
pub fn cast_is_silently_ignored_test() {
  let subject = start()

  let reply_sub = process.new_subject()
  sm.cast(subject, pushbutton.Push(reply_sub))

  // No reply arrives.
  process.receive(reply_sub, 50) |> should.equal(Error(Nil))
  // And the count is unchanged.
  pushbutton.get_count(subject) |> should.equal(0)
}
