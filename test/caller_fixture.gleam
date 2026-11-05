//// Obtain an actual OTP caller token for structural effect comparisons.

import eparch/state_machine as sm
import gleam/erlang/process

pub fn token() -> sm.From(Int) {
  let seen = process.new_subject()
  let assert Ok(server) =
    sm.new(Nil, Nil)
    |> sm.on_event(fn(event, _, _) {
      case event {
        sm.Call(from, Nil) -> {
          process.send(seen, from)
          sm.stop_and_reply(process.Normal, [#(from, 0)])
        }
        _ -> sm.keep_state_and_data([])
      }
    })
    |> sm.start_link
  let request = sm.send_request(server.ref, Nil)
  assert sm.receive_response(request, 1000) == Ok(0)
  let assert Ok(from) = process.receive(seen, 1000)
  from
}
