//// Cluster workload: eparch clients across real Erlang distribution.
////
//// Three `peer` nodes run on loopback. Host `a` runs an echo state machine
//// under a `Global` name; host `b` runs an event manager with one handler.
//// The client replays a seeded script of calls and publications mixed with
//// partitions and kills, tracking what it can reach and what it believes
//// is alive. Every call that runs on `a` is recorded in a ledger that
//// survives server restarts.

import eparch/event_manager as bus
import eparch/state_machine as statem
import eparch/workload/verdict.{type Verdict}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Pid}
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import qcheck

const call_timeout = 100

const slow_delay = 250

const wait = 5000

/// Below the driver's 120 s budget, so a hung run is reported here.
const run_timeout = 90_000

pub type Host {
  HostA
  HostB
}

/// How long the echo server takes: `Slow` outlasts the call timeout.
pub type Pace {
  Prompt
  Slow
}

pub type Op {
  Call(Pace)
  Notify
  Isolate(Host)
  Heal
  KillServer
  StartServer
  KillManager
  StartManager
}

pub type Request {
  Echo(id: Int, delay: Int)
}

pub type Reply {
  Echoed(id: Int)
}

/// One call to the global echo server, with the client's beliefs at the
/// time it was made.
pub type CallOutcome {
  CallOutcome(
    id: Int,
    pace: Pace,
    reachable: Bool,
    alive: Bool,
    result: Result(Reply, statem.ReceiveError),
  )
}

/// One `sync_notify` to the remote manager, with the client's beliefs.
pub type NotifyOutcome {
  NotifyOutcome(reachable: Bool, alive: Bool, result: bus.SyncResult)
}

pub type Outcome {
  Called(CallOutcome)
  Notified(NotifyOutcome)
  Applied(Op)
  Failed(Op)
  Skipped(Op)
}

pub type SetupError {
  HostsUnreachable
  LedgerUnavailable
  ServerNotStarted
  ManagerNotStarted
}

pub type Report {
  Finished(
    seed: Int,
    script: List(Op),
    outcomes: List(Outcome),
    ledger: Result(List(Int), Nil),
    leftover_messages: Int,
  )
  SetupFailed(seed: Int, script: List(Op), error: SetupError)
  Crashed(seed: Int, script: List(Op), reason: String)
}

type Node

type Ledger

type ClientResult =
  Result(#(List(Outcome), Result(List(Int), Nil), Int), SetupError)

@external(erlang, "eparch_cluster_ffi", "run")
fn run_cluster(
  client: fn(Node, Node) -> ClientResult,
  timeout: Int,
) -> Result(ClientResult, String)

@external(erlang, "eparch_cluster_ffi", "remote")
fn remote(node: Node, run: fn() -> a, timeout: Int) -> Result(a, Nil)

@external(erlang, "eparch_cluster_ffi", "isolate")
fn isolate(node: Node) -> Bool

@external(erlang, "eparch_cluster_ffi", "heal")
fn heal(nodes: List(Node)) -> Bool

@external(erlang, "eparch_cluster_ffi", "kill_and_wait")
fn kill_and_wait(pid: Pid) -> Bool

@external(erlang, "eparch_cluster_ffi", "global_whereis")
fn global_whereis(name: Atom) -> Result(Pid, Nil)

@external(erlang, "eparch_cluster_ffi", "new_ledger")
fn new_ledger() -> Ledger

@external(erlang, "eparch_cluster_ffi", "ledger_record")
fn ledger_record(ledger: Ledger, id: Int) -> Nil

@external(erlang, "eparch_cluster_ffi", "ledger_ids")
fn ledger_ids(ledger: Ledger) -> List(Int)

@external(erlang, "eparch_workload_ffi", "mailbox_length")
fn mailbox_length() -> Int

@external(erlang, "erlang", "nodes")
fn connected_nodes() -> List(Node)

fn echo_name() -> Atom {
  atom.create("eparch_cluster_echo")
}

fn op_gen() -> qcheck.Generator(Op) {
  let pace =
    qcheck.from_generators(qcheck.return(Prompt), [qcheck.return(Slow)])
  let host =
    qcheck.from_generators(qcheck.return(HostA), [qcheck.return(HostB)])
  qcheck.from_weighted_generators(#(6, qcheck.map(pace, Call)), [
    #(3, qcheck.return(Notify)),
    #(2, qcheck.map(host, Isolate)),
    #(2, qcheck.return(Heal)),
    #(1, qcheck.return(KillServer)),
    #(1, qcheck.return(StartServer)),
    #(1, qcheck.return(KillManager)),
    #(1, qcheck.return(StartManager)),
  ])
}

/// Scripts of 4 to 24 operations.
pub fn script_gen() -> qcheck.Generator(List(Op)) {
  qcheck.generic_list(op_gen(), qcheck.bounded_int(4, 24))
}

/// Run one seeded script on a fresh cluster.
pub fn run(seed: Int) -> Report {
  let script = case qcheck.generate(script_gen(), 1, qcheck.seed(seed)) {
    #([script, ..], _) -> script
    #([], _) -> []
  }
  case run_cluster(fn(a, b) { client(script, a, b) }, run_timeout) {
    Ok(Ok(#(outcomes, ledger, leftover))) ->
      Finished(seed:, script:, outcomes:, ledger:, leftover_messages: leftover)
    Ok(Error(error)) -> SetupFailed(seed:, script:, error:)
    Error(reason) -> Crashed(seed:, script:, reason:)
  }
}

// Host side: runs on `a` and `b` through `remote`.

fn start_echo(ledger: Ledger) -> Result(statem.ServerRef(Request, Reply), Nil) {
  statem.new(initial_state: Nil, initial_data: ledger)
  |> statem.on_event(fn(event, _state, ledger) {
    case event {
      statem.Call(from, Echo(id, delay)) -> {
        process.sleep(delay)
        ledger_record(ledger, id)
        statem.keep_state(ledger, [statem.reply(from, Echoed(id))])
      }
      statem.Cast(_)
      | statem.Info(_)
      | statem.RawInfo(_)
      | statem.Internal(_)
      | statem.Enter(_)
      | statem.Timeout(..) -> statem.keep_state_and_data([])
    }
  })
  |> statem.named(statem.Global(echo_name()))
  |> statem.start
  |> result.map(fn(started) { started.ref })
  |> result.replace_error(Nil)
}

fn start_manager() -> Result(bus.Manager(Int), Nil) {
  use manager <- result.try(
    bus.start(bus.new_start_options()) |> result.replace_error(Nil),
  )
  let handler = bus.new_handler(Nil, fn(_event, state) { bus.Continue(state) })
  bus.add_handler(manager, handler, on_down: None)
  |> result.replace(manager)
  |> result.replace_error(Nil)
}

// Client side: runs on the client peer.

type World {
  World(
    host_a: Node,
    host_b: Node,
    ledger: Ledger,
    server: statem.ServerRef(Request, Reply),
    manager: bus.Manager(Int),
    reaches_a: Bool,
    reaches_b: Bool,
    server_alive: Bool,
    manager_alive: Bool,
    next_id: Int,
  )
}

fn client(script: List(Op), host_a: Node, host_b: Node) -> ClientResult {
  let baseline = mailbox_length()
  use world <- result.map(setup(host_a, host_b))
  let #(world, outcomes) =
    list.fold(script, #(world, []), fn(acc, op) {
      let #(world, outcomes) = acc
      let #(world, outcome) = step(world, op)
      #(world, [outcome, ..outcomes])
    })
  let _ = heal([host_a, host_b])
  let ledger = remote(host_a, fn() { ledger_ids(world.ledger) }, wait)
  #(list.reverse(outcomes), ledger, mailbox_length() - baseline)
}

fn setup(host_a: Node, host_b: Node) -> Result(World, SetupError) {
  use <- require(heal([host_a, host_b]), HostsUnreachable)
  use ledger <- result.try(
    remote(host_a, new_ledger, wait) |> result.replace_error(LedgerUnavailable),
  )
  use server <- result.try(
    remote(host_a, fn() { start_echo(ledger) }, wait)
    |> result.flatten
    |> result.replace_error(ServerNotStarted),
  )
  use manager <- result.map(
    remote(host_b, start_manager, wait)
    |> result.flatten
    |> result.replace_error(ManagerNotStarted),
  )
  World(
    host_a:,
    host_b:,
    ledger:,
    server:,
    manager:,
    reaches_a: True,
    reaches_b: True,
    server_alive: True,
    manager_alive: True,
    next_id: 0,
  )
}

fn require(
  condition: Bool,
  error: SetupError,
  next: fn() -> Result(World, SetupError),
) -> Result(World, SetupError) {
  case condition {
    True -> next()
    False -> Error(error)
  }
}

fn step(world: World, op: Op) -> #(World, Outcome) {
  case op {
    Call(pace) -> {
      let id = world.next_id
      let delay = case pace {
        Prompt -> 0
        Slow -> slow_delay
      }
      let result =
        statem.call(world.server, Echo(id, delay), waiting: call_timeout)
      let outcome =
        CallOutcome(
          id:,
          pace:,
          reachable: world.reaches_a,
          alive: world.server_alive,
          result:,
        )
      #(World(..world, next_id: id + 1), Called(outcome))
    }

    Notify -> {
      let result = bus.sync_notify(world.manager, 0, wait)
      let outcome =
        NotifyOutcome(
          reachable: world.reaches_b,
          alive: world.manager_alive,
          result:,
        )
      #(world, Notified(outcome))
    }

    Isolate(host) ->
      case reaches(world, host) {
        True -> {
          let outcome = applied(op, isolate(node(world, host)))
          #(observe(world), outcome)
        }
        False -> #(world, Skipped(op))
      }

    Heal ->
      case world.reaches_a && world.reaches_b {
        True -> #(world, Skipped(op))
        False -> {
          let outcome = applied(op, heal([world.host_a, world.host_b]))
          #(observe(world), outcome)
        }
      }

    KillServer ->
      case world.reaches_a && world.server_alive {
        True -> {
          let killed = case global_whereis(echo_name()) {
            Ok(pid) -> kill_and_wait(pid)
            Error(Nil) -> False
          }
          #(World(..world, server_alive: !killed), applied(op, killed))
        }
        False -> #(world, Skipped(op))
      }

    StartServer ->
      case world.reaches_a && !world.server_alive {
        True -> {
          let ledger = world.ledger
          let started = case
            remote(world.host_a, fn() { start_echo(ledger) }, wait)
          {
            Ok(Ok(_)) -> True
            Ok(Error(Nil)) | Error(Nil) -> False
          }
          #(World(..world, server_alive: started), applied(op, started))
        }
        False -> #(world, Skipped(op))
      }

    KillManager ->
      case world.reaches_b && world.manager_alive {
        True -> {
          let killed = kill_and_wait(bus.manager_pid(world.manager))
          #(World(..world, manager_alive: !killed), applied(op, killed))
        }
        False -> #(world, Skipped(op))
      }

    StartManager ->
      case world.reaches_b && !world.manager_alive {
        True ->
          case remote(world.host_b, start_manager, wait) {
            Ok(Ok(manager)) -> #(
              World(..world, manager:, manager_alive: True),
              Applied(op),
            )
            Ok(Error(Nil)) | Error(Nil) -> #(world, Failed(op))
          }
        False -> #(world, Skipped(op))
      }
  }
}

fn applied(op: Op, succeeded: Bool) -> Outcome {
  case succeeded {
    True -> Applied(op)
    False -> Failed(op)
  }
}

fn node(world: World, host: Host) -> Node {
  case host {
    HostA -> world.host_a
    HostB -> world.host_b
  }
}

fn reaches(world: World, host: Host) -> Bool {
  case host {
    HostA -> world.reaches_a
    HostB -> world.reaches_b
  }
}

/// Reachability as the client's own node sees it.
fn observe(world: World) -> World {
  let nodes = connected_nodes()
  World(
    ..world,
    reaches_a: list.contains(nodes, world.host_a),
    reaches_b: list.contains(nodes, world.host_b),
  )
}

// Oracle.

pub fn verdicts(report: Report) -> List(Verdict) {
  let details = string.inspect(report)
  let outcomes = case report {
    Finished(outcomes:, ..) -> outcomes
    SetupFailed(..) | Crashed(..) -> []
  }
  let calls =
    list.filter_map(outcomes, fn(outcome) {
      case outcome {
        Called(call) -> Ok(call)
        Notified(_) | Applied(_) | Failed(_) | Skipped(_) -> Error(Nil)
      }
    })
  let notifications =
    list.filter_map(outcomes, fn(outcome) {
      case outcome {
        Notified(notification) -> Ok(notification)
        Called(_) | Applied(_) | Failed(_) | Skipped(_) -> Error(Nil)
      }
    })
  let issued = list.map(calls, fn(call) { call.id })
  let replied =
    list.filter_map(calls, fn(call) {
      result.map(call.result, fn(reply) { reply.id })
    })
  let effects = case report {
    Finished(ledger: Ok(effects), ..) -> effects
    Finished(ledger: Error(Nil), ..) | SetupFailed(..) | Crashed(..) -> []
  }
  [
    verdict.always(
      case report {
        SetupFailed(..) -> False
        Finished(..) | Crashed(..) -> True
      },
      "The cluster client starts both hosts",
      details,
    ),
    verdict.always(
      case report {
        Crashed(..) | Finished(ledger: Error(Nil), ..) -> False
        Finished(ledger: Ok(_), ..) | SetupFailed(..) -> True
      },
      "The cluster client finishes and reads its ledger",
      details,
    ),
    verdict.always(
      list.all(calls, fn(call) {
        case call.result {
          Ok(Echoed(id)) -> id == call.id
          Error(_) -> True
        }
      }),
      "A cross-node call returns only its own reply",
      details,
    ),
    verdict.always(
      list.unique(effects) == effects
        && list.all(effects, list.contains(issued, _)),
      "A cross-node call takes effect at most once",
      details,
    ),
    verdict.always(
      list.all(replied, list.contains(effects, _)),
      "A successful cross-node call took effect",
      details,
    ),
    verdict.always(
      list.all(calls, fn(call) {
        call.reachable || result.is_error(call.result)
      }),
      "A global server on an unreachable node never replies",
      details,
    ),
    verdict.always(
      case report {
        Finished(leftover_messages:, ..) -> leftover_messages == 0
        SetupFailed(..) | Crashed(..) -> True
      },
      "Late cross-node replies never reach the caller",
      details,
    ),
    verdict.always(
      list.all(notifications, fn(n) {
        n.alive || n.result == bus.SyncManagerDown
      }),
      "A dead remote manager is reported down, never timed out",
      details,
    ),
    verdict.always(
      list.all(notifications, fn(n) {
        n.reachable || n.result == bus.SyncManagerDown
      }),
      "An unreachable manager is reported down",
      details,
    ),
    verdict.sometimes(
      list.any(calls, fn(call) { result.is_ok(call.result) }),
      "A cross-node call succeeds",
      details,
    ),
    verdict.sometimes(
      list.any(calls, fn(call) { call.result == Error(statem.ReceiveTimeout) }),
      "A cross-node call times out",
      details,
    ),
    verdict.sometimes(
      list.any(calls, fn(call) {
        !call.reachable && result.is_error(call.result)
      }),
      "A call to an isolated node's global server fails",
      details,
    ),
    verdict.sometimes(
      list.any(notifications, fn(n) { n.result == bus.Confirmed }),
      "A reachable remote manager confirms a publication",
      details,
    ),
    verdict.sometimes(
      list.any(notifications, fn(n) {
        !n.reachable && n.alive && n.result == bus.SyncManagerDown
      }),
      "A live but unreachable manager is reported down",
      details,
    ),
  ]
}
