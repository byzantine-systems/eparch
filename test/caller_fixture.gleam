//// Obtain an actual OTP caller token for structural effect comparisons.

import eparch/state_machine as sm
import gleam/erlang/process

pub fn token() -> sm.From(Int) {
  token_for(0)
}

/// A real caller token whose phantom reply type matches `reply`. The value
/// is only used to complete the probe call that captures the token.
pub fn token_for(reply: a) -> sm.From(a) {
  let seen = process.new_subject()
  let assert Ok(server) =
    sm.new(Nil, Nil)
    |> sm.on_event(fn(event, _, _) {
      case event {
        sm.Call(from, Nil) -> {
          process.send(seen, from)
          sm.stop_and_reply(process.Normal, [#(from, reply)])
        }
        _ -> sm.keep_state_and_data([])
      }
    })
    |> sm.start_link
  let request = sm.send_request(server.ref, Nil)
  assert sm.receive_response(request, 1000) == Ok(reply)
  let assert Ok(from) = process.receive(seen, 1000)
  from
}
