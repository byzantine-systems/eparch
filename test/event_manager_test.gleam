import eparch/event_manager as bus
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import qcheck

const wait = 1000

fn start() {
  let assert Ok(manager) = bus.start_link(bus.new_start_options())
  manager
}

fn take(inbox: Subject(a)) -> a {
  let assert Ok(value) = process.receive(inbox, wait)
  value
}

type Command {
  Toggle(slot: Int)
  Publish(value: Int)
}

// A subscriber's trace is the projection of the history onto its active
// intervals. There is no promised order *between* different callbacks.
fn expected(history: List(Command), slot: Int) -> List(Int) {
  let #(_, events) =
    list.fold(history, #(False, []), fn(acc, command) {
      let #(active, events) = acc
      case command {
        Toggle(i) if i == slot -> #(!active, events)
        Publish(n) if active -> #(active, [n, ..events])
        _ -> acc
      }
    })
  list.reverse(events)
}

fn received(inbox: Subject(a)) -> List(a) {
  case process.receive(inbox, 0) {
    Ok(value) -> [value, ..received(inbox)]
    Error(Nil) -> []
  }
}

fn collector(inbox: Subject(a)) {
  bus.new_handler(Nil, fn(event, _) {
    process.send(inbox, event)
    bus.Continue(Nil)
  })
}

pub fn subscription_history_test() {
  let slots = [0, 1, 2]
  let command =
    qcheck.from_weighted_generators(
      #(2, qcheck.map(qcheck.bounded_int(0, 2), Toggle)),
      [#(3, qcheck.map(qcheck.bounded_int(-8, 8), Publish))],
    )
  use history <- qcheck.run(
    qcheck.default_config() |> qcheck.with_test_count(100),
    qcheck.generic_list(command, qcheck.bounded_int(0, 30)),
  )
  let manager = start()
  let inboxes =
    dict.from_list(list.map(slots, fn(i) { #(i, process.new_subject()) }))
  let active =
    list.fold(history, dict.new(), fn(active, command) {
      case command {
        Publish(n) -> {
          bus.notify(manager, n)
          active
        }
        Toggle(i) ->
          case dict.get(active, i) {
            Ok(ref) -> {
              let assert Ok(Nil) = bus.remove_handler(manager, ref, wait)
              dict.delete(active, i)
            }
            Error(Nil) -> {
              let assert Ok(inbox) = dict.get(inboxes, i)
              let assert Ok(ref) =
                bus.add_handler(manager, collector(inbox), on_down: None)
              dict.insert(active, i, ref)
            }
          }
      }
    })
  let assert Ok(ids) = bus.which_handlers(manager)
  // Removal is a drain barrier. Now all three mailboxes can be inspected
  // without guessing how long a missing or duplicate event might take.
  list.each(dict.values(active), fn(ref) {
    let assert Ok(Nil) = bus.remove_handler(manager, ref, wait)
    Nil
  })
  let remaining = bus.which_handlers(manager)
  bus.stop(manager, wait)
  assert remaining == Ok([])
  assert list.length(ids) == dict.size(active)
  assert list.unique(ids) == ids
  list.each(slots, fn(i) {
    let assert Ok(inbox) = dict.get(inboxes, i)
    assert received(inbox) == expected(history, i)
  })
}

pub fn callback_crash_spares_registrar_and_sibling_test() {
  let manager = start()
  let ready = process.new_subject()
  let survived = process.new_subject()
  let _registrar =
    process.spawn_unlinked(fn() {
      let down = process.new_subject()
      let crash =
        bus.new_handler(Nil, fn(_, _) { panic as "injected handler failure" })
      let assert Ok(_) = bus.add_handler(manager, crash, on_down: Some(down))
      process.send(ready, Nil)
      // Sending this receipt requires the registrar itself to have survived.
      process.send(survived, take(down))
    })
  take(ready)
  let assert Ok([failed]) = bus.which_handlers(manager)
  let events = process.new_subject()
  let assert Ok(_) = bus.add_handler(manager, collector(events), on_down: None)
  let outcome = bus.sync_notify(manager, 1, wait)
  let down = process.receive(survived, wait)
  let remaining = bus.which_handlers(manager)
  let next = bus.sync_notify(manager, 2, wait)
  bus.stop(manager, wait)
  assert outcome == bus.Unconfirmed([failed])
  let assert Ok(bus.HandlerDown(id, reason)) = down
  assert id == failed
  assert reason != process.Normal
  let assert Ok([sibling]) = remaining
  assert sibling != failed
  assert next == bus.Confirmed
  assert received(events) == [1, 2]
}

pub fn stalled_handler_does_not_block_dispatch_or_cancel_timed_out_work_test() {
  let manager = start()
  let entered = process.new_subject()
  let cleanup = process.new_subject()
  let down = process.new_subject()
  let slow =
    bus.new_handler([], fn(n, events) {
      case n {
        1 -> {
          let gate = process.new_subject()
          process.send(entered, gate)
          let assert Ok(Nil) = process.receive(gate, 4000)
          Nil
        }
        _ -> Nil
      }
      bus.Continue([n, ..events])
    })
    |> bus.on_terminate(fn(events) {
      process.send(cleanup, list.reverse(events))
    })
  let assert Ok(ref) = bus.add_handler(manager, slow, on_down: Some(down))
  let fast = process.new_subject()
  let assert Ok(_) = bus.add_handler(manager, collector(fast), on_down: None)
  bus.notify(manager, 1)
  let gate = take(entered)
  let outcome = bus.sync_notify(manager, 2, 20)
  let first = take(fast)
  let second = take(fast)
  let removal = bus.remove_handler(manager, ref, 20)
  process.send(gate, Nil)
  let drained = take(cleanup)
  let stale = bus.remove_handler(manager, ref, wait)
  let next = bus.sync_notify(manager, 3, wait)
  bus.stop(manager, wait)
  assert outcome == bus.SyncTimeout
  assert #(first, second) == #(1, 2)
  assert removal == Error(bus.RemoveTimedOut)
  assert drained == [1, 2]
  assert stale == Error(bus.HandlerNotFound)
  assert next == bus.Confirmed
  assert received(fast) == [3]
  assert received(down) == []
}

pub fn abrupt_manager_death_does_not_orphan_idle_handler_test() {
  let manager = start()
  let pids = process.new_subject()
  let handler =
    bus.new_handler(Nil, fn(_, _) {
      process.send(pids, process.self())
      bus.Continue(Nil)
    })
  let assert Ok(_) = bus.add_handler(manager, handler, on_down: None)
  let assert bus.Confirmed = bus.sync_notify(manager, Nil, wait)
  let worker = take(pids)
  let monitor = process.monitor(worker)
  let pid = bus.manager_pid(manager)
  process.unlink(pid)
  process.kill(pid)
  let down =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(d) { d })
    |> process.selector_receive(wait)
  // Reap the worker even on the regression path.
  case down {
    Error(Nil) -> {
      process.unlink(worker)
      process.kill(worker)
      process.demonitor_process(monitor)
    }
    Ok(_) -> Nil
  }
  let assert Ok(process.ProcessDown(pid: dead, ..)) = down
  assert dead == worker
}
