////
//// Model-based law for request-id collections (OTP 25+).
////
//// The model is the ordered list of associations a collection holds, each
//// either still awaiting its reply or already consumed (`Keep`). A single
//// server answers requests in arrival order, so replies reach the caller in
//// send order. After every generated command the real collection must agree
//// with the model on `request_ids_size` and on the multiset of labels in
//// `request_ids_to_list`, and every receive must return exactly what the
//// model predicts:
////
//// - empty collection: `NoRequests`;
//// - some association awaiting: `GotReply` for the oldest one, with
////   `Delete` removing it and `Keep` retaining it as consumed;
//// - only consumed associations: `CollectionTimeout`, after which OTP
////   abandons the collection and the run ends.
////

import eparch/state_machine
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/result
import qcheck

type Command {
  SendToCollection(label: Int)
  SendThenAdd(label: Int)
  Receive(handling: state_machine.ResponseHandling)
}

type Association {
  Association(label: Int, awaiting: Bool)
}

type Echo {
  Echo(label: Int)
}

fn echo_server() -> state_machine.Started(Echo, Int) {
  let assert Ok(machine) =
    state_machine.new(initial_state: Nil, initial_data: Nil)
    |> state_machine.on_event(fn(event, _, _) {
      case event {
        state_machine.Call(from, Echo(label)) ->
          state_machine.keep_state_and_data([state_machine.Reply(from, label)])
        state_machine.Cast(_)
        | state_machine.Info(_)
        | state_machine.RawInfo(_)
        | state_machine.Internal(_)
        | state_machine.Enter(_)
        | state_machine.Timeout(_, _) -> state_machine.keep_state_and_data([])
      }
    })
    |> state_machine.start
  machine
}

fn command_gen() -> qcheck.Generator(Command) {
  let label = qcheck.bounded_int(0, 5)
  qcheck.from_weighted_generators(#(3, qcheck.map(label, SendToCollection)), [
    #(2, qcheck.map(label, SendThenAdd)),
    #(2, qcheck.return(Receive(state_machine.Delete))),
    #(1, qcheck.return(Receive(state_machine.Keep))),
  ])
}

fn labels(model: List(Association)) -> List(Int) {
  model
  |> list.map(fn(association) { association.label })
  |> list.sort(int.compare)
}

fn agree(
  collection: state_machine.RequestIdCollection(Int, Int),
  model: List(Association),
) -> Nil {
  assert state_machine.request_ids_size(collection) == list.length(model)
  let listed =
    state_machine.request_ids_to_list(collection)
    |> list.map(fn(pair) { pair.1 })
    |> list.sort(int.compare)
  assert listed == labels(model)
}

/// Mark the oldest awaiting association consumed (`Keep`) or drop it
/// (`Delete`). Returns its label, or `Error(Nil)` when none is awaiting.
fn take_oldest(
  model: List(Association),
  handling: state_machine.ResponseHandling,
) -> Result(#(Int, List(Association)), Nil) {
  case model {
    [] -> Error(Nil)
    [first, ..rest] if first.awaiting ->
      case handling {
        state_machine.Delete -> Ok(#(first.label, rest))
        state_machine.Keep ->
          Ok(#(first.label, [Association(first.label, False), ..rest]))
      }
    [first, ..rest] -> {
      use #(label, rest) <- result.map(take_oldest(rest, handling))
      #(label, [first, ..rest])
    }
  }
}

type Run {
  Live(
    collection: state_machine.RequestIdCollection(Int, Int),
    model: List(Association),
  )
  Abandoned
}

fn apply(
  run: Run,
  command: Command,
  server: state_machine.Started(Echo, Int),
) -> Run {
  case run {
    Abandoned -> Abandoned
    Live(collection, model) -> {
      let next = case command {
        SendToCollection(label) ->
          Live(
            state_machine.send_request_to_collection(
              server.ref,
              Echo(label),
              label,
              collection,
            ),
            list.append(model, [Association(label, True)]),
          )
        SendThenAdd(label) ->
          Live(
            state_machine.request_ids_add(
              request_id: state_machine.send_request(server.ref, Echo(label)),
              label: label,
              to: collection,
            ),
            list.append(model, [Association(label, True)]),
          )
        Receive(handling) -> receive(collection, model, handling)
      }
      case next {
        Live(collection, model) -> agree(collection, model)
        Abandoned -> Nil
      }
      next
    }
  }
}

fn receive(
  collection: state_machine.RequestIdCollection(Int, Int),
  model: List(Association),
  handling: state_machine.ResponseHandling,
) -> Run {
  let outcome =
    state_machine.receive_response_collection(collection, 20, handling)
  case model, take_oldest(model, handling) {
    [], _ -> {
      assert outcome == state_machine.NoRequests
      Live(collection, model)
    }
    _, Ok(#(label, model)) -> {
      let assert state_machine.GotReply(reply, got_label, collection) = outcome
      assert reply == label
      assert got_label == label
      Live(collection, model)
    }
    [_, ..], Error(Nil) -> {
      assert outcome == state_machine.CollectionTimeout
      Abandoned
    }
  }
}

pub fn request_id_collections_follow_their_model_test() {
  let server = echo_server()
  use commands <- qcheck.run(
    qcheck.default_config() |> qcheck.with_test_count(60),
    qcheck.generic_list(command_gen(), qcheck.bounded_int(0, 12)),
  )
  let start = Live(state_machine.request_ids_new(), [])
  let _ =
    list.fold(commands, start, fn(run, command) { apply(run, command, server) })
  // Replies to associations never received stay in the mailbox.
  process.flush_messages()
}
