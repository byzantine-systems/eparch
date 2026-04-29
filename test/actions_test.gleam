////
//// Integration tests for gen_statem actions: Stop, Postpone, NextEvent,
//// StateTimeout, GenericTimeout, Cast, and reqids (send_request).
////
//// Each section has its own state/msg types, prefixed to avoid constructor
//// name collisions across sections.
////

import eparch/state_machine
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/string
import gleeunit/should

@external(erlang, "sys", "get_status")
fn sys_get_status(pid: process.Pid) -> Dynamic

@external(erlang, "erlang", "process_info")
fn process_info(pid: process.Pid, key: atom.Atom) -> Dynamic

// STOP
type StopState {
  StopRunning
}

type StopMsg {
  Shutdown
}

fn stop_handler(
  event: state_machine.Event(StopState, StopMsg, Nil),
  _state: StopState,
  data: Nil,
) -> state_machine.Step(StopState, Nil, StopMsg, Nil) {
  case event {
    state_machine.Info(Shutdown) -> state_machine.stop(process.Normal)
    _ -> state_machine.keep_state(data, [])
  }
}

pub fn stop_normal_terminates_process_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: StopRunning, initial_data: Nil)
    |> state_machine.on_event(stop_handler)
    |> state_machine.start

  let monitor = process.monitor(machine.pid)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })

  process.send(machine.data, Shutdown)

  let assert Ok(down) = process.selector_receive(selector, 1000)
  down.reason |> should.equal(process.Normal)
}

// POSTPONE
type PostponeState {
  PostWaiting
  PostReady
}

type PostponeMsg {
  Go
  Action(reply_with: process.Subject(String))
}

fn postpone_handler(
  event: state_machine.Event(PostponeState, PostponeMsg, Nil),
  state: PostponeState,
  data: Nil,
) -> state_machine.Step(PostponeState, Nil, PostponeMsg, Nil) {
  case event, state {
    state_machine.Info(Action(_)), PostWaiting ->
      state_machine.keep_state(data, [state_machine.Postpone])

    state_machine.Info(Go), PostWaiting ->
      state_machine.next_state(PostReady, data, [])

    state_machine.Info(Action(reply_with: reply_sub)), PostReady -> {
      process.send(reply_sub, "handled")
      state_machine.keep_state(data, [])
    }

    _, _ -> state_machine.keep_state(data, [])
  }
}

pub fn postpone_redelivers_event_after_state_change_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: PostWaiting, initial_data: Nil)
    |> state_machine.on_event(postpone_handler)
    |> state_machine.start

  let reply_sub = process.new_subject()
  // Action arrives first but is postponed; Go triggers state change -> redeliver.
  process.send(machine.data, Action(reply_with: reply_sub))
  process.send(machine.data, Go)

  let assert Ok(reply) = process.receive(reply_sub, 1000)
  reply |> should.equal("handled")
}

// NEXT EVENT
// 1. Trigger 
// 2. NextEvent(Derived) -> internal event fires as Cast (Derived).

type NextEventState {
  NeActive
}

type NextEventMsg {
  Trigger(reply_with: process.Subject(String))
  Derived(reply_with: process.Subject(String))
}

fn next_event_handler(
  event: state_machine.Event(NextEventState, NextEventMsg, Nil),
  _state: NextEventState,
  data: Nil,
) -> state_machine.Step(NextEventState, Nil, NextEventMsg, Nil) {
  case event {
    state_machine.Info(Trigger(reply_with: reply_sub)) ->
      state_machine.keep_state(data, [
        state_machine.NextEvent(state_machine.CastEvent, Derived(reply_sub)),
      ])

    state_machine.Cast(Derived(reply_with: reply_sub)) -> {
      process.send(reply_sub, "derived")
      state_machine.keep_state(data, [])
    }

    _ -> state_machine.keep_state(data, [])
  }
}

pub fn next_event_fires_synthesised_cast_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: NeActive, initial_data: Nil)
    |> state_machine.on_event(next_event_handler)
    |> state_machine.start

  let reply_sub = process.new_subject()
  process.send(machine.data, Trigger(reply_with: reply_sub))

  let assert Ok(reply) = process.receive(reply_sub, 1000)
  reply |> should.equal("derived")
}

// STATE TIMEOUT
type StTimeoutState {
  StIdle
  StActive
  StTimedOut
}

type StTimeoutMsg {
  StActivate
  StGetState(reply_with: process.Subject(StTimeoutState))
}

fn state_timeout_handler(
  event: state_machine.Event(StTimeoutState, StTimeoutMsg, Nil),
  state: StTimeoutState,
  data: Nil,
) -> state_machine.Step(StTimeoutState, Nil, StTimeoutMsg, Nil) {
  case event, state {
    state_machine.Info(StActivate), StIdle ->
      state_machine.next_state(StActive, data, [state_machine.StateTimeout(10)])

    state_machine.Timeout(state_machine.StateTimeoutType), StActive ->
      state_machine.next_state(StTimedOut, data, [])

    state_machine.Info(StGetState(reply_with: reply_sub)), _ -> {
      process.send(reply_sub, state)
      state_machine.keep_state(data, [])
    }

    _, _ -> state_machine.keep_state(data, [])
  }
}

pub fn state_timeout_fires_and_transitions_state_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: StIdle, initial_data: Nil)
    |> state_machine.on_event(state_timeout_handler)
    |> state_machine.start

  process.send(machine.data, StActivate)
  process.sleep(30)

  let reply_sub = process.new_subject()
  process.send(machine.data, StGetState(reply_with: reply_sub))

  let assert Ok(s) = process.receive(reply_sub, 1000)
  s |> should.equal(StTimedOut)
}

// State timeout is cancelled when leaving the state.
type CancelState {
  CIdle
  CActive
  CDone
}

type CancelMsg {
  CActivate
  CLeave
  CGetState(reply_with: process.Subject(CancelState))
}

fn cancel_handler(
  event: state_machine.Event(CancelState, CancelMsg, Nil),
  state: CancelState,
  data: Nil,
) -> state_machine.Step(CancelState, Nil, CancelMsg, Nil) {
  case event, state {
    state_machine.Info(CActivate), CIdle ->
      state_machine.next_state(CActive, data, [state_machine.StateTimeout(5000)])

    state_machine.Info(CLeave), CActive ->
      state_machine.next_state(CDone, data, [])

    state_machine.Info(CGetState(reply_with: reply_sub)), _ -> {
      process.send(reply_sub, state)
      state_machine.keep_state(data, [])
    }

    _, _ -> state_machine.keep_state(data, [])
  }
}

pub fn state_timeout_is_cancelled_on_state_change_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: CIdle, initial_data: Nil)
    |> state_machine.on_event(cancel_handler)
    |> state_machine.start

  process.send(machine.data, CActivate)
  process.send(machine.data, CLeave)

  let reply_sub = process.new_subject()
  process.send(machine.data, CGetState(reply_with: reply_sub))
  let assert Ok(s) = process.receive(reply_sub, 1000)
  s |> should.equal(CDone)
}

// GENERIC TIMEOUT
type GenTimeoutState {
  GtWaiting
  GtTriggered
}

type GenTimeoutMsg {
  GtArm
  GtGetState(reply_with: process.Subject(GenTimeoutState))
}

fn generic_timeout_handler(
  event: state_machine.Event(GenTimeoutState, GenTimeoutMsg, Nil),
  state: GenTimeoutState,
  data: Nil,
) -> state_machine.Step(GenTimeoutState, Nil, GenTimeoutMsg, Nil) {
  case event, state {
    state_machine.Info(GtArm), GtWaiting ->
      state_machine.keep_state(data, [state_machine.GenericTimeout("tick", 10)])

    state_machine.Timeout(state_machine.GenericTimeoutType("tick")), GtWaiting ->
      state_machine.next_state(GtTriggered, data, [])

    state_machine.Info(GtGetState(reply_with: reply_sub)), _ -> {
      process.send(reply_sub, state)
      state_machine.keep_state(data, [])
    }

    _, _ -> state_machine.keep_state(data, [])
  }
}

pub fn generic_timeout_fires_after_interval_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: GtWaiting, initial_data: Nil)
    |> state_machine.on_event(generic_timeout_handler)
    |> state_machine.start

  process.send(machine.data, GtArm)
  process.sleep(30)

  let reply_sub = process.new_subject()
  process.send(machine.data, GtGetState(reply_with: reply_sub))
  let assert Ok(s) = process.receive(reply_sub, 1000)
  s |> should.equal(GtTriggered)
}

type CstState {
  CstIdle
  CstActive
  CstTimedOut
}

type CstMsg {
  CstActivate
  CstCancel
  CstGetState(reply_with: process.Subject(CstState))
}

fn cancel_state_timeout_handler(
  event: state_machine.Event(CstState, CstMsg, Nil),
  state: CstState,
  data: Nil,
) -> state_machine.Step(CstState, Nil, CstMsg, Nil) {
  case event, state {
    state_machine.Info(CstActivate), CstIdle ->
      state_machine.next_state(CstActive, data, [
        state_machine.StateTimeout(5000),
      ])

    state_machine.Info(CstCancel), CstActive ->
      state_machine.keep_state(data, [state_machine.cancel_state_timeout()])

    state_machine.Timeout(state_machine.StateTimeoutType), CstActive ->
      state_machine.next_state(CstTimedOut, data, [])

    state_machine.Info(CstGetState(reply_with: reply_sub)), _ -> {
      process.send(reply_sub, state)
      state_machine.keep_state(data, [])
    }

    _, _ -> state_machine.keep_state(data, [])
  }
}

pub fn cancel_state_timeout_prevents_fire_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: CstIdle, initial_data: Nil)
    |> state_machine.on_event(cancel_state_timeout_handler)
    |> state_machine.start

  process.send(machine.data, CstActivate)
  process.send(machine.data, CstCancel)
  process.sleep(30)

  let reply_sub = process.new_subject()
  process.send(machine.data, CstGetState(reply_with: reply_sub))
  let assert Ok(s) = process.receive(reply_sub, 1000)
  s |> should.equal(CstActive)
}

type CgtState {
  CgtWaiting
  CgtTriggered
}

type CgtMsg {
  CgtArm
  CgtCancel
  CgtGetState(reply_with: process.Subject(CgtState))
}

fn cancel_generic_timeout_handler(
  event: state_machine.Event(CgtState, CgtMsg, Nil),
  state: CgtState,
  data: Nil,
) -> state_machine.Step(CgtState, Nil, CgtMsg, Nil) {
  case event, state {
    state_machine.Info(CgtArm), CgtWaiting ->
      state_machine.keep_state(data, [
        state_machine.GenericTimeout("tick", 5000),
      ])

    state_machine.Info(CgtCancel), CgtWaiting ->
      state_machine.keep_state(data, [
        state_machine.cancel_generic_timeout("tick"),
      ])

    state_machine.Timeout(state_machine.GenericTimeoutType("tick")), CgtWaiting ->
      state_machine.next_state(CgtTriggered, data, [])

    state_machine.Info(CgtGetState(reply_with: reply_sub)), _ -> {
      process.send(reply_sub, state)
      state_machine.keep_state(data, [])
    }

    _, _ -> state_machine.keep_state(data, [])
  }
}

pub fn cancel_generic_timeout_prevents_fire_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: CgtWaiting, initial_data: Nil)
    |> state_machine.on_event(cancel_generic_timeout_handler)
    |> state_machine.start

  process.send(machine.data, CgtArm)
  process.send(machine.data, CgtCancel)
  process.sleep(30)

  let reply_sub = process.new_subject()
  process.send(machine.data, CgtGetState(reply_with: reply_sub))
  let assert Ok(s) = process.receive(reply_sub, 1000)
  s |> should.equal(CgtWaiting)
}

type UstState {
  UstWaiting
  UstFired
}

type UstMsg {
  UstArm
  UstUpdate
  UstGetState(reply_with: process.Subject(UstState))
}

fn update_state_timeout_handler(
  event: state_machine.Event(UstState, UstMsg, Nil),
  state: UstState,
  data: Nil,
) -> state_machine.Step(UstState, Nil, UstMsg, Nil) {
  case event, state {
    state_machine.Info(UstArm), UstWaiting ->
      state_machine.keep_state(data, [state_machine.StateTimeout(200)])

    state_machine.Info(UstUpdate), UstWaiting ->
      state_machine.keep_state(data, [
        state_machine.update_state_timeout(UstUpdate),
      ])

    state_machine.Timeout(state_machine.StateTimeoutType), UstWaiting ->
      state_machine.next_state(UstFired, data, [])

    state_machine.Info(UstGetState(reply_with: reply_sub)), _ -> {
      process.send(reply_sub, state)
      state_machine.keep_state(data, [])
    }

    _, _ -> state_machine.keep_state(data, [])
  }
}

pub fn update_state_timeout_fires_without_restart_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: UstWaiting, initial_data: Nil)
    |> state_machine.on_event(update_state_timeout_handler)
    |> state_machine.start

  process.send(machine.data, UstArm)
  process.send(machine.data, UstUpdate)
  process.sleep(300)

  let reply_sub = process.new_subject()
  process.send(machine.data, UstGetState(reply_with: reply_sub))
  let assert Ok(s) = process.receive(reply_sub, 1000)
  s |> should.equal(UstFired)
}

// CAST
//
// 1. state_machine.cast delivers `Cast(msg)`.
// 2. state_machine.send delivers Info(msg).
// 3. The handler only responds to `Cast`, `Info` is silently dropped.
type CastState {
  CastListening
}

type CastMsg {
  Ping(reply_with: process.Subject(String))
}

fn cast_handler(
  event: state_machine.Event(CastState, CastMsg, Nil),
  _state: CastState,
  data: Nil,
) -> state_machine.Step(CastState, Nil, CastMsg, Nil) {
  case event {
    state_machine.Cast(Ping(reply_with: reply_sub)) -> {
      process.send(reply_sub, "pong")
      state_machine.keep_state(data, [])
    }
    _ -> state_machine.keep_state(data, [])
  }
}

pub fn cast_delivers_message_as_cast_event_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: CastListening, initial_data: Nil)
    |> state_machine.on_event(cast_handler)
    |> state_machine.start

  let reply_sub = process.new_subject()
  state_machine.cast(machine.data, Ping(reply_with: reply_sub))

  let assert Ok(reply) = process.receive(reply_sub, 1000)
  reply |> should.equal("pong")
}

pub fn send_delivers_message_as_info_not_cast_test() {
  // state_machine.send -> Info(msg)
  // handler only handles Cast -> no reply -> timeout.
  let assert Ok(machine) =
    state_machine.new(initial_state: CastListening, initial_data: Nil)
    |> state_machine.on_event(cast_handler)
    |> state_machine.start

  let reply_sub = process.new_subject()
  state_machine.send(machine.data, Ping(reply_with: reply_sub))

  process.receive(reply_sub, 50) |> should.equal(Error(Nil))
}

// CHANGE CALLBACK MODULE
//
// Switching to `statem_ffi` itself is a safe no-op: the machine keeps the
// same behaviour but exercises the FFI translation path end-to-end.
type CbState {
  CbListening
}

type CbMsg {
  CbSwitch
  CbPing(reply_with: process.Subject(String))
}

fn change_callback_handler(
  event: state_machine.Event(CbState, CbMsg, Nil),
  _state: CbState,
  data: Nil,
) -> state_machine.Step(CbState, Nil, CbMsg, Nil) {
  case event {
    state_machine.Info(CbSwitch) ->
      state_machine.keep_state(data, [
        state_machine.change_callback_module(atom.create("statem_ffi")),
      ])

    state_machine.Info(CbPing(reply_with: reply_sub)) -> {
      process.send(reply_sub, "pong")
      state_machine.keep_state(data, [])
    }

    _ -> state_machine.keep_state(data, [])
  }
}

pub fn change_callback_module_keeps_machine_alive_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: CbListening, initial_data: Nil)
    |> state_machine.on_event(change_callback_handler)
    |> state_machine.start

  process.send(machine.data, CbSwitch)

  let reply_sub = process.new_subject()
  process.send(machine.data, CbPing(reply_with: reply_sub))

  let assert Ok(reply) = process.receive(reply_sub, 1000)
  reply |> should.equal("pong")
}

// PUSH / POP CALLBACK MODULE
fn push_pop_handler(
  event: state_machine.Event(CbState, CbMsg, Nil),
  _state: CbState,
  data: Nil,
) -> state_machine.Step(CbState, Nil, CbMsg, Nil) {
  case event {
    state_machine.Info(CbSwitch) ->
      state_machine.keep_state(data, [
        state_machine.push_callback_module(atom.create("statem_ffi")),
        state_machine.pop_callback_module(),
      ])

    state_machine.Info(CbPing(reply_with: reply_sub)) -> {
      process.send(reply_sub, "pong")
      state_machine.keep_state(data, [])
    }

    _ -> state_machine.keep_state(data, [])
  }
}

pub fn push_then_pop_callback_module_roundtrip_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: CbListening, initial_data: Nil)
    |> state_machine.on_event(push_pop_handler)
    |> state_machine.start

  process.send(machine.data, CbSwitch)

  let reply_sub = process.new_subject()
  process.send(machine.data, CbPing(reply_with: reply_sub))

  let assert Ok(reply) = process.receive(reply_sub, 1000)
  reply |> should.equal("pong")
}

// REQIDS (send_request / OTP 25+)
//
// The server receives Call(from, msg) events and must reply with the
// Reply(from, value) action. This is different from the Info-based pattern
// used by state_machine.call / process.call.
//

type ReqState {
  ReqRunning
}

type ReqMsg {
  GetCounter
  Increment
}

fn reqid_handler(
  event: state_machine.Event(ReqState, ReqMsg, Int),
  _state: ReqState,
  data: Int,
) -> state_machine.Step(ReqState, Int, ReqMsg, Int) {
  case event {
    state_machine.Call(from, GetCounter) ->
      state_machine.keep_state(data, [state_machine.Reply(from, data)])
    state_machine.Info(Increment) -> state_machine.keep_state(data + 1, [])
    _ -> state_machine.keep_state(data, [])
  }
}

pub fn send_request_returns_reply_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: ReqRunning, initial_data: 0)
    |> state_machine.on_event(reqid_handler)
    |> state_machine.start

  let request: state_machine.RequestId(Int) =
    state_machine.send_request(machine.data, GetCounter)
  let assert Ok(count) = state_machine.receive_response(request, 1000)
  count |> should.equal(0)
}

pub fn send_request_sees_latest_state_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: ReqRunning, initial_data: 0)
    |> state_machine.on_event(reqid_handler)
    |> state_machine.start

  process.send(machine.data, Increment)
  process.send(machine.data, Increment)

  let request: state_machine.RequestId(Int) =
    state_machine.send_request(machine.data, GetCounter)
  let assert Ok(count) = state_machine.receive_response(request, 1000)
  count |> should.equal(2)
}

pub fn request_ids_size_reflects_pending_requests_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: ReqRunning, initial_data: 0)
    |> state_machine.on_event(reqid_handler)
    |> state_machine.start

  let collection: state_machine.RequestIdCollection(String, Int) =
    state_machine.request_ids_new()
  state_machine.request_ids_size(collection) |> should.equal(0)

  let collection =
    state_machine.send_request_to_collection(
      machine.data,
      GetCounter,
      "first",
      collection,
    )
  state_machine.request_ids_size(collection) |> should.equal(1)

  let collection =
    state_machine.send_request_to_collection(
      machine.data,
      GetCounter,
      "second",
      collection,
    )
  state_machine.request_ids_size(collection) |> should.equal(2)

  let assert state_machine.GotReply(_, _, collection) =
    state_machine.receive_response_collection(
      collection,
      1000,
      state_machine.Delete,
    )
  let assert state_machine.GotReply(_, _, collection) =
    state_machine.receive_response_collection(
      collection,
      1000,
      state_machine.Delete,
    )
  state_machine.request_ids_size(collection) |> should.equal(0)
}

pub fn send_request_to_collection_delivers_both_replies_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: ReqRunning, initial_data: 42)
    |> state_machine.on_event(reqid_handler)
    |> state_machine.start

  let collection: state_machine.RequestIdCollection(String, Int) =
    state_machine.request_ids_new()
  let collection =
    state_machine.send_request_to_collection(
      machine.data,
      GetCounter,
      "a",
      collection,
    )
  let collection =
    state_machine.send_request_to_collection(
      machine.data,
      GetCounter,
      "b",
      collection,
    )

  let assert state_machine.GotReply(value1, _label1, collection) =
    state_machine.receive_response_collection(
      collection,
      1000,
      state_machine.Delete,
    )
  let assert state_machine.GotReply(value2, _label2, _) =
    state_machine.receive_response_collection(
      collection,
      1000,
      state_machine.Delete,
    )

  value1 |> should.equal(42)
  value2 |> should.equal(42)
}

pub fn request_ids_to_list_contains_all_entries_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: ReqRunning, initial_data: 0)
    |> state_machine.on_event(reqid_handler)
    |> state_machine.start

  let collection: state_machine.RequestIdCollection(String, Int) =
    state_machine.request_ids_new()
  let collection =
    state_machine.send_request_to_collection(
      machine.data,
      GetCounter,
      "x",
      collection,
    )
  let collection =
    state_machine.send_request_to_collection(
      machine.data,
      GetCounter,
      "y",
      collection,
    )

  let entries = state_machine.request_ids_to_list(collection)
  list.length(entries) |> should.equal(2)

  let assert state_machine.GotReply(_, _, collection) =
    state_machine.receive_response_collection(
      collection,
      1000,
      state_machine.Delete,
    )
  let assert state_machine.GotReply(_, _, _) =
    state_machine.receive_response_collection(
      collection,
      1000,
      state_machine.Delete,
    )
}

pub fn request_ids_add_manually_adds_to_collection_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: ReqRunning, initial_data: 7)
    |> state_machine.on_event(reqid_handler)
    |> state_machine.start

  let request: state_machine.RequestId(Int) =
    state_machine.send_request(machine.data, GetCounter)
  let collection: state_machine.RequestIdCollection(String, Int) =
    state_machine.request_ids_new()
  let collection =
    state_machine.request_ids_add(
      request_id: request,
      label: "manual",
      to: collection,
    )
  state_machine.request_ids_size(collection) |> should.equal(1)

  let assert state_machine.GotReply(value, label, _) =
    state_machine.receive_response_collection(
      collection,
      1000,
      state_machine.Delete,
    )
  value |> should.equal(7)
  label |> should.equal("manual")
}

// STOP AND REPLY
type SarState {
  SarRunning
}

type SarMsg {
  SarGetAndStop
}

fn stop_and_reply_handler(
  event: state_machine.Event(SarState, SarMsg, String),
  _state: SarState,
  _data: Nil,
) -> state_machine.Step(SarState, Nil, SarMsg, String) {
  case event {
    state_machine.Call(from, SarGetAndStop) ->
      state_machine.stop_and_reply(process.Normal, [
        state_machine.Reply(from, "bye"),
      ])
    _ -> state_machine.keep_state(Nil, [])
  }
}

pub fn stop_and_reply_sends_reply_before_stopping_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: SarRunning, initial_data: Nil)
    |> state_machine.on_event(stop_and_reply_handler)
    |> state_machine.start

  let monitor = process.monitor(machine.pid)
  let sel =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(d) { d })

  let req: state_machine.RequestId(String) =
    state_machine.send_request(machine.data, SarGetAndStop)
  let assert Ok(reply) = state_machine.receive_response(req, 1000)
  reply |> should.equal("bye")

  let assert Ok(down) = process.selector_receive(sel, 1000)
  down.reason |> should.equal(process.Normal)
}

// HIBERNATE AFTER
type HibState {
  HibIdle
}

type HibMsg {
  HibPing(reply_with: process.Subject(String))
}

fn hibernate_after_handler(
  event: state_machine.Event(HibState, HibMsg, Nil),
  _state: HibState,
  data: Nil,
) -> state_machine.Step(HibState, Nil, HibMsg, Nil) {
  case event {
    state_machine.Info(HibPing(reply_with: reply_sub)) -> {
      process.send(reply_sub, "pong")
      state_machine.keep_state(data, [])
    }
    _ -> state_machine.keep_state(data, [])
  }
}

// Configures a 10ms timer, sleeps 50ms, checks process_info(pid, current_function) 
// reports gen_statem:loop_hibernate/3, then verifies the machine still responds
// to a message after waking.
pub fn hibernate_after_puts_idle_process_into_hibernation_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: HibIdle, initial_data: Nil)
    |> state_machine.hibernate_after(10)
    |> state_machine.on_event(hibernate_after_handler)
    |> state_machine.start

  // Wait long enough for the idle timer to fire. When hibernating, the
  // process's current_function is gen_statem:loop_hibernate/3.
  process.sleep(50)

  let info = process_info(machine.pid, atom.create("current_function"))
  string.inspect(info)
  |> string.contains("Hibernate")
  |> should.equal(True)

  // Sending a message wakes the process; the handler still runs.
  let reply_sub = process.new_subject()
  process.send(machine.data, HibPing(reply_with: reply_sub))
  let assert Ok(reply) = process.receive(reply_sub, 1000)
  reply |> should.equal("pong")
}

// Negative control confirming the option is actually doing the work.
pub fn machine_without_hibernate_after_does_not_hibernate_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: HibIdle, initial_data: Nil)
    |> state_machine.on_event(hibernate_after_handler)
    |> state_machine.start

  process.sleep(50)

  let info = process_info(machine.pid, atom.create("current_function"))
  string.inspect(info)
  |> string.contains("Hibernate")
  |> should.equal(False)
}

// ON FORMAT STATUS
type FmtState {
  FmtIdle
  FmtReady
}

type FmtMsg {
  FmtGoReady
}

type FmtData {
  FmtSecret(value: Int)
  FmtRedacted(label: String)
}

fn fmt_handler(
  event: state_machine.Event(FmtState, FmtMsg, Nil),
  _state: FmtState,
  data: FmtData,
) -> state_machine.Step(FmtState, FmtData, FmtMsg, Nil) {
  case event {
    state_machine.Info(FmtGoReady) ->
      state_machine.next_state(FmtReady, data, [])
    _ -> state_machine.keep_state(data, [])
  }
}

pub fn on_format_status_overrides_data_in_status_report_test() {
  let assert Ok(machine) =
    state_machine.new(
      initial_state: FmtIdle,
      initial_data: FmtSecret(value: 42),
    )
    |> state_machine.on_event(fmt_handler)
    |> state_machine.on_format_status(fn(status) {
      let label = case status.data {
        FmtSecret(value: v) -> "FORMATTED:" <> int.to_string(v)
        FmtRedacted(label: l) -> l
      }
      state_machine.Status(..status, data: FmtRedacted(label: label))
    })
    |> state_machine.start

  let status = sys_get_status(machine.pid)
  string.inspect(status)
  |> string.contains("FORMATTED:42")
  |> should.equal(True)
}

pub fn machine_without_format_status_still_appears_in_status_test() {
  let assert Ok(machine) =
    state_machine.new(initial_state: FmtIdle, initial_data: FmtSecret(value: 0))
    |> state_machine.on_event(fmt_handler)
    |> state_machine.start

  // Should not crash; sys:get_status returns a non-empty term.
  let _ = sys_get_status(machine.pid)
  Nil
}
