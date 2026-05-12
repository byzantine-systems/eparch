////
//// Integration tests for the door lock state machine.
////
//// These tests spawn a real gen_statem process and exercise the full
//// message-passing lifecycle: `button` (cast), `get_status` (call), and
//// the auto-lock state timeout.
////
//// The auto-lock timeout is set to 100 ms (via `start_with_lock_timeout`)
//// so timeout tests complete quickly without sleeping for 5 seconds.
////

import doorlock
import eparch/state_machine as sm
import gleam/erlang/process
import gleeunit/should

// Constants & Helpers
const code = [1, 2, 3, 4]

/// Start a lock with the default 5-second auto-lock.
fn start() -> sm.ServerRef(doorlock.Message) {
  let assert Ok(machine) = doorlock.start(code)
  machine.ref
}

/// Start a lock with a short auto-lock for timeout tests.
fn start_fast() -> sm.ServerRef(doorlock.Message) {
  let assert Ok(machine) = doorlock.start_with_lock_timeout(code, 100)
  machine.ref
}

// Tests
/// A freshly started lock is in the Locked state.
pub fn initial_state_is_locked_test() {
  let ref = start()
  doorlock.get_status(ref) |> should.equal(doorlock.Locked)
}

/// Pressing the full correct sequence opens the lock.
pub fn correct_sequence_opens_the_lock_test() {
  let ref = start()

  doorlock.enter_code(ref, code)
  doorlock.get_status(ref) |> should.equal(doorlock.Open)
}

/// Pressing buttons one at a time also opens the lock.
pub fn one_button_at_a_time_opens_the_lock_test() {
  let ref = start()

  doorlock.button(ref, 1)
  doorlock.get_status(ref) |> should.equal(doorlock.Locked)
  doorlock.button(ref, 2)
  doorlock.get_status(ref) |> should.equal(doorlock.Locked)
  doorlock.button(ref, 3)
  doorlock.get_status(ref) |> should.equal(doorlock.Locked)
  doorlock.button(ref, 4)
  doorlock.get_status(ref) |> should.equal(doorlock.Open)
}

/// A wrong digit in the middle of the sequence resets the buffer.
pub fn wrong_digit_resets_progress_test() {
  let ref = start()

  // Two correct, then one wrong -> buffer resets, still Locked.
  doorlock.button(ref, 1)
  doorlock.button(ref, 2)
  doorlock.button(ref, 9)
  doorlock.get_status(ref) |> should.equal(doorlock.Locked)

  // Continuing with 3, 4 alone is not enough; we need the full code.
  doorlock.button(ref, 3)
  doorlock.button(ref, 4)
  doorlock.get_status(ref) |> should.equal(doorlock.Locked)

  // Now the full correct sequence opens it.
  doorlock.enter_code(ref, code)
  doorlock.get_status(ref) |> should.equal(doorlock.Open)
}

/// Button presses while Open are silently ignored.
pub fn buttons_while_open_are_ignored_test() {
  let ref = start()

  doorlock.enter_code(ref, code)
  doorlock.get_status(ref) |> should.equal(doorlock.Open)

  doorlock.button(ref, 9)
  doorlock.button(ref, 9)
  doorlock.get_status(ref) |> should.equal(doorlock.Open)
}

/// After the auto-lock timeout fires, the door transitions back to Locked.
pub fn auto_lock_relocks_after_timeout_test() {
  let ref = start_fast()

  doorlock.enter_code(ref, code)
  doorlock.get_status(ref) |> should.equal(doorlock.Open)

  // Wait long enough for the 100 ms state timeout to fire.
  process.sleep(250)

  doorlock.get_status(ref) |> should.equal(doorlock.Locked)
}

/// After auto-lock, the correct sequence can re-open the door.
pub fn can_reopen_after_auto_lock_test() {
  let ref = start_fast()

  doorlock.enter_code(ref, code)
  process.sleep(250)
  doorlock.get_status(ref) |> should.equal(doorlock.Locked)

  doorlock.enter_code(ref, code)
  doorlock.get_status(ref) |> should.equal(doorlock.Open)
}
