//// Workload entry point for the Antithesis driver and local smoke runs.
////
//// ```sh
//// gleam dev -- broadcast 8 normal
//// gleam dev -- broadcast 8 kill
//// gleam dev -- statem 42
//// ```
////
//// Each evaluated property is printed as one `EPARCH {json}` line; the
//// driver maps them onto Antithesis SDK assertions. Arguments come from a
//// fixed vocabulary and are parsed, never turned into atoms.

import eparch/workload/broadcast
import eparch/workload/statem
import eparch/workload/verdict.{type Verdict}
import gleam/int
import gleam/io
import gleam/list

type Scenario {
  Broadcast(burst: Int, mode: broadcast.Mode)
  Statem(seed: Int)
}

@external(erlang, "eparch_workload_ffi", "plain_arguments")
fn plain_arguments() -> List(String)

@external(erlang, "eparch_workload_ffi", "halt")
fn halt(status: Int) -> Nil

pub fn main() -> Nil {
  case parse(plain_arguments()) {
    Ok(scenario) -> {
      scenario
      |> run
      |> list.each(fn(v) { io.println("EPARCH " <> verdict.to_json(v)) })
      halt(0)
    }
    Error(Nil) -> {
      io.println_error(
        "usage: broadcast <burst 1..16> <normal|kill> | statem <seed>",
      )
      halt(2)
    }
  }
}

fn parse(arguments: List(String)) -> Result(Scenario, Nil) {
  case arguments {
    ["broadcast", burst, mode] -> {
      let mode = case mode {
        "normal" -> Ok(broadcast.Normal)
        "kill" -> Ok(broadcast.Kill)
        _ -> Error(Nil)
      }
      case int.parse(burst), mode {
        Ok(burst), Ok(mode) if burst >= 1 && burst <= 16 ->
          Ok(Broadcast(burst, mode))
        _, _ -> Error(Nil)
      }
    }
    ["statem", seed] ->
      case int.parse(seed) {
        Ok(seed) -> Ok(Statem(seed))
        Error(Nil) -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn run(scenario: Scenario) -> List(Verdict) {
  case scenario {
    Broadcast(burst, mode) -> broadcast.verdicts(broadcast.run(burst, mode))
    Statem(seed) -> statem.verdicts(statem.run(seed))
  }
}
