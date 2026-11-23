//// Broadcast workload: one manager and its worker actors, driven only
//// through the public `eparch/event_manager` API.
////
//// `Normal` checks the snapshot and admission claims: an explicit callback
//// gate holds the first confirmation open while a second worker registers,
//// with exactly one confirmation slot. `Kill` kills the manager while that
//// confirmation is outstanding and checks every client result afterwards.
//// No assumption is made about callback order across workers.

import eparch/event_manager as bus
import eparch/workload/verdict.{type Verdict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string

const wait = 10_000

pub type Mode {
  Normal
  Kill
}

pub type Event {
  Number(Int)
  Gate
  Pressure
  Fence
}

pub type Role {
  Early
  Late
}

type Receipts

@external(erlang, "eparch_workload_ffi", "new_receipts")
fn new_receipts() -> Receipts

@external(erlang, "eparch_workload_ffi", "record")
fn record(receipts: Receipts, role: Role, event: Event) -> Nil

@external(erlang, "eparch_workload_ffi", "trace")
fn trace(receipts: Receipts, role: Role) -> List(Event)

pub type Report {
  NormalReport(
    burst: Int,
    first: bus.SyncResult,
    at_return: List(Event),
    pressure: bus.SyncResult,
    final: bus.SyncResult,
    early: List(Event),
    late: List(Event),
  )
  KillReport(
    burst: Int,
    first: bus.SyncResult,
    pressure: bus.SyncResult,
    added: Result(Nil, bus.AddError),
    stopped: Result(Nil, bus.StopError),
    early: List(Event),
  )
}

/// Run one scenario. `burst` asynchronous publications precede the gated
/// confirmation; it is clamped to 1..16.
pub fn run(burst: Int, mode: Mode) -> Report {
  let burst = int.clamp(burst, min: 1, max: 16)
  let receipts = new_receipts()
  // Unlinked, so killing the manager cannot take the workload with it.
  let assert Ok(manager) =
    bus.new_start_options()
    |> bus.with_max_in_flight_sync(1)
    |> bus.start
  let entered = process.new_subject()
  let firsts = process.new_subject()
  add(manager, Early, receipts, entered)
  let _ =
    process.spawn(fn() {
      list.each(numbers(burst), bus.notify(manager, _))
      let result = bus.sync_notify(manager, Gate, wait)
      process.send(firsts, #(result, trace(receipts, Early)))
    })
  let assert Ok(release) = process.receive(entered, wait)
  case mode {
    Normal -> normal(manager, receipts, entered, release, firsts, burst)
    Kill -> kill(manager, receipts, release, firsts, burst)
  }
}

fn normal(
  manager: bus.Manager(Event),
  receipts: Receipts,
  entered: Subject(Subject(Nil)),
  release: Subject(Nil),
  firsts: Subject(#(bus.SyncResult, List(Event))),
  burst: Int,
) -> Report {
  // Callback entry witnesses acceptance; this registration cannot precede it.
  add(manager, Late, receipts, entered)
  let pressure = bus.sync_notify(manager, Pressure, wait)
  process.send(release, Nil)
  let assert Ok(#(first, at_return)) = process.receive(firsts, wait)
  let final = bus.sync_notify(manager, Fence, wait)
  let _ = bus.stop(manager, wait)
  NormalReport(
    burst:,
    first:,
    at_return:,
    pressure:,
    final:,
    early: trace(receipts, Early),
    late: trace(receipts, Late),
  )
}

fn kill(
  manager: bus.Manager(Event),
  receipts: Receipts,
  release: Subject(Nil),
  firsts: Subject(#(bus.SyncResult, List(Event))),
  burst: Int,
) -> Report {
  let pid = bus.manager_pid(manager)
  let monitor = process.monitor(pid)
  process.kill(pid)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(wait)
  // The manager is gone before these calls start, so no deadline can expire
  // first: anything but a "manager down" result is a defect.
  let pressure = bus.sync_notify(manager, Pressure, wait)
  let added =
    bus.add_handler(
      manager,
      bus.new_handler(Nil, fn(_, state) { bus.Continue(state) }),
      on_down: None,
    )
    |> result_to_nil
  let stopped = bus.stop(manager, wait)
  process.send(release, Nil)
  let assert Ok(#(first, _)) = process.receive(firsts, wait)
  KillReport(
    burst:,
    first:,
    pressure:,
    added:,
    stopped:,
    early: trace(receipts, Early),
  )
}

fn result_to_nil(result: Result(a, e)) -> Result(Nil, e) {
  case result {
    Ok(_) -> Ok(Nil)
    Error(error) -> Error(error)
  }
}

fn add(
  manager: bus.Manager(Event),
  role: Role,
  receipts: Receipts,
  entered: Subject(Subject(Nil)),
) -> Nil {
  let handler =
    bus.new_handler(Nil, fn(event, state) {
      case role, event {
        Early, Gate -> {
          let release = process.new_subject()
          process.send(entered, release)
          case process.receive(release, 4 * wait) {
            Ok(Nil) -> Nil
            Error(Nil) -> panic as "workload gate was never released"
          }
        }
        Early, _ | Late, _ -> Nil
      }
      record(receipts, role, event)
      bus.Continue(state)
    })
  let assert Ok(_) = bus.add_handler(manager, handler, on_down: None)
  Nil
}

/// The oracle: every claim this report can evaluate, as verdicts.
pub fn verdicts(report: Report) -> List(Verdict) {
  let details = string.inspect(report)
  case report {
    NormalReport(burst, first, at_return, pressure, final, early, late) -> {
      let prefix = list.append(numbers(burst), [Gate])
      let recovered = pressure == bus.SyncBusy && final == bus.Confirmed
      list.flatten([
        when(first == bus.Confirmed, [
          verdict.always(
            at_return == prefix,
            "Confirmed prefix equals completed callback trace",
            details,
          ),
        ]),
        [
          verdict.sometimes(
            recovered,
            "A saturated manager accepts a later fence",
            details,
          ),
        ],
        when(final == bus.Confirmed, [
          verdict.always(
            !list.any(late, fn(event) { event == Gate || is_number(event) }),
            "Late registration excludes the accepted prefix",
            details,
          ),
          verdict.always(
            count(early, Fence) == 1 && count(late, Fence) == 1,
            "Confirmed fence reaches both current handlers once",
            details,
          ),
        ]),
        when(final == bus.Confirmed && pressure == bus.SyncBusy, [
          verdict.always(
            count(early, Pressure) == 0 && count(late, Pressure) == 0,
            "Busy publication leaves no callback receipt",
            details,
          ),
        ]),
        // The gate is held throughout this call. A timeout is
        // inconclusive; any other result contradicts the cap of one.
        when(pressure != bus.SyncTimeout, [
          verdict.always(
            pressure == bus.SyncBusy,
            "Occupied sync slot rejects another publication",
            details,
          ),
        ]),
      ])
    }
    KillReport(_, first, pressure, added, stopped, _) -> [
      verdict.always(
        pressure == bus.SyncManagerDown,
        "A publication to a dead manager reports it down, never a timeout",
        details,
      ),
      verdict.always(
        added == Error(bus.AddManagerDown),
        "Registering with a dead manager reports it down",
        details,
      ),
      verdict.always(
        stopped == Error(bus.AlreadyStopped),
        "Stopping a dead manager reports it already stopped",
        details,
      ),
      verdict.always(
        first != bus.Confirmed,
        "A confirmation is never reported once its handler was killed mid-callback",
        details,
      ),
      verdict.sometimes(
        first == bus.SyncManagerDown,
        "An outstanding confirmation observes the manager's death",
        details,
      ),
    ]
  }
}

fn when(condition: Bool, verdicts: List(Verdict)) -> List(Verdict) {
  case condition {
    True -> verdicts
    False -> []
  }
}

/// `[Number(1), ..., Number(burst)]`, in publication order.
fn numbers(burst: Int) -> List(Event) {
  int.range(from: burst, to: 0, with: [], run: fn(acc, n) { [Number(n), ..acc] })
}

fn is_number(event: Event) -> Bool {
  case event {
    Number(_) -> True
    Gate | Pressure | Fence -> False
  }
}

fn count(events: List(Event), wanted: Event) -> Int {
  list.count(events, fn(event) { event == wanted })
}
