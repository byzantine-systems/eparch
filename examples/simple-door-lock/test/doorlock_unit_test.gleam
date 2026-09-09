import doorlock
import eparch/state_machine as sm
import gleam/erlang/process
import gleeunit/should

const code = [1, 2, 3, 4]

const data = doorlock.Data(code: [1, 2, 3, 4], buttons: [])

const timeout_ms = 5000

fn call(event, state) {
  doorlock.handle_event(timeout_ms, event, state, data)
}

pub fn append_without_reaching_capacity_test() {
  doorlock.append_and_cap([1, 2], 3, 4) |> should.equal([1, 2, 3])
}

pub fn append_evicts_oldest_at_capacity_test() {
  doorlock.append_and_cap([9, 1, 2, 3], 4, 4)
  |> should.equal([1, 2, 3, 4])
}

pub fn partial_sequence_is_retained_test() {
  call(sm.Cast(doorlock.Button(1)), doorlock.Locked)
  |> should.equal(sm.KeepState(doorlock.Data(code: code, buttons: [1]), []))
}

pub fn nonmatching_full_window_is_retained_test() {
  let full = doorlock.Data(code: code, buttons: [9, 1, 2])
  doorlock.handle_event(
    timeout_ms,
    sm.Cast(doorlock.Button(3)),
    doorlock.Locked,
    full,
  )
  |> should.equal(
    sm.KeepState(doorlock.Data(code: code, buttons: [9, 1, 2, 3]), []),
  )
}

pub fn matching_window_opens_and_clears_buttons_test() {
  let partial = doorlock.Data(code: code, buttons: [1, 2, 3])
  doorlock.handle_event(
    timeout_ms,
    sm.Cast(doorlock.Button(4)),
    doorlock.Locked,
    partial,
  )
  |> should.equal(
    sm.NextState(doorlock.Open, doorlock.Data(code: code, buttons: []), []),
  )
}

pub fn entering_locked_clears_buttons_test() {
  let partial = doorlock.Data(code: code, buttons: [2, 3])
  doorlock.handle_event(
    timeout_ms,
    sm.Enter(doorlock.Open),
    doorlock.Locked,
    partial,
  )
  |> should.equal(sm.KeepState(doorlock.Data(code: code, buttons: []), []))
}

pub fn entering_open_sets_timeout_test() {
  call(sm.Enter(doorlock.Locked), doorlock.Open)
  |> should.equal(
    sm.KeepStateAndData([
      sm.StateTimeout(sm.After(timeout_ms), doorlock.AutoLock),
    ]),
  )
}

pub fn state_entry_runs_only_the_corresponding_effect_test() {
  let subject = process.new_subject()
  let lock = fn() { process.send(subject, "lock") }
  let unlock = fn() { process.send(subject, "unlock") }

  doorlock.handle_event_with_effects(
    timeout_ms,
    sm.Enter(doorlock.Open),
    doorlock.Locked,
    data,
    lock,
    unlock,
  )
  process.receive(subject, 0) |> should.equal(Ok("lock"))

  doorlock.handle_event_with_effects(
    timeout_ms,
    sm.Enter(doorlock.Locked),
    doorlock.Open,
    data,
    lock,
    unlock,
  )
  process.receive(subject, 0) |> should.equal(Ok("unlock"))
}

pub fn button_while_open_is_noop_test() {
  call(sm.Cast(doorlock.Button(1)), doorlock.Open)
  |> should.equal(sm.KeepStateAndData([]))
}

pub fn state_timeout_while_open_transitions_to_locked_test() {
  call(sm.Timeout(sm.StateTimeoutType, doorlock.AutoLock), doorlock.Open)
  |> should.equal(sm.NextState(doorlock.Locked, data, []))
}

pub fn empty_code_never_opens_test() {
  let empty = doorlock.Data(code: [], buttons: [])
  doorlock.handle_event(
    timeout_ms,
    sm.Cast(doorlock.Button(1)),
    doorlock.Locked,
    empty,
  )
  |> should.equal(sm.KeepState(empty, []))
}
