////
//// Unit tests for the door lock event handler.
////
//// These tests call `handle_event` directly without spawning a process,
//// so they run fast and are deterministic. They cover `Cast`, `Enter`,
//// and `Timeout` events — the `Call(GetStatus)` path is covered by the
//// integration tests because `From` is opaque and can only be produced
//// by the gen_statem runtime.
////

import doorlock
import eparch/state_machine as sm
import gleeunit/should

// Constants & Helpers
const code = [1, 2, 3, 4]

const data = doorlock.Data(code: [1, 2, 3, 4], remaining: [1, 2, 3, 4])

const timeout_ms = 5000

fn call(event, state) {
  doorlock.handle_event(timeout_ms, event, state, data)
}

// Button (Locked State)
/// A correct prefix digit consumes one digit from `remaining`.
pub fn correct_first_digit_consumes_one_test() {
  let expected = doorlock.Data(code: code, remaining: [2, 3, 4])

  call(sm.Cast(doorlock.Button(1)), doorlock.Locked)
  |> should.equal(sm.KeepState(expected, []))
}

/// Completing the final digit transitions to Open and resets the buffer.
pub fn final_correct_digit_opens_lock_test() {
  let one_left = doorlock.Data(code: code, remaining: [4])
  let reset = doorlock.Data(code: code, remaining: code)

  doorlock.handle_event(
    timeout_ms,
    sm.Cast(doorlock.Button(4)),
    doorlock.Locked,
    one_left,
  )
  |> should.equal(sm.NextState(doorlock.Open, reset, []))
}

/// A wrong digit resets the buffer back to the full code.
pub fn wrong_digit_resets_buffer_test() {
  let partial = doorlock.Data(code: code, remaining: [3, 4])
  let reset = doorlock.Data(code: code, remaining: code)

  doorlock.handle_event(
    timeout_ms,
    sm.Cast(doorlock.Button(9)),
    doorlock.Locked,
    partial,
  )
  |> should.equal(sm.KeepState(reset, []))
}

// Button (Open State)
/// Button presses while Open are silently ignored.
pub fn button_while_open_is_noop_test() {
  call(sm.Cast(doorlock.Button(1)), doorlock.Open)
  |> should.equal(sm.KeepStateAndData([]))
}

// State Enter
/// Entering the Locked state resets the digit buffer.
pub fn entering_locked_resets_buffer_test() {
  let partial = doorlock.Data(code: code, remaining: [3, 4])
  let reset = doorlock.Data(code: code, remaining: code)

  doorlock.handle_event(
    timeout_ms,
    sm.Enter(doorlock.Open),
    doorlock.Locked,
    partial,
  )
  |> should.equal(sm.KeepState(reset, []))
}

/// Entering the Open state arms the auto-lock timer.
pub fn entering_open_state_sets_timeout_test() {
  call(sm.Enter(doorlock.Locked), doorlock.Open)
  |> should.equal(
    sm.KeepStateAndData([
      sm.StateTimeout(sm.After(timeout_ms), doorlock.AutoLock),
    ]),
  )
}

// State Timeout
/// When the state timeout fires while Open, the door re-locks.
pub fn state_timeout_while_open_transitions_to_locked_test() {
  call(sm.Timeout(sm.StateTimeoutType, doorlock.AutoLock), doorlock.Open)
  |> should.equal(sm.NextState(doorlock.Locked, data, []))
}

/// A state timeout while already Locked is a no-op (catch-all branch).
pub fn state_timeout_while_locked_is_noop_test() {
  call(sm.Timeout(sm.StateTimeoutType, doorlock.AutoLock), doorlock.Locked)
  |> should.equal(sm.KeepStateAndData([]))
}

// Info / Unknown
/// Info messages are silently ignored — the lock only listens to Cast and Call.
pub fn info_events_are_ignored_test() {
  call(sm.Info(doorlock.GetStatus), doorlock.Locked)
  |> should.equal(sm.KeepStateAndData([]))
}
