-module(eparch_test_helpers).
-moduledoc """
Test-only helpers for the Gleam suites. Pure encoding glue:
build the Erlang-shape values that Gleam cannot construct through its
own type system (e.g. the raw `{global, Name}` tuple consumed by
`gen_statem:cast/2`).
""".

-export([
    while_suspended/2,
    encode_global_target/1,
    encode_atom_as_term/1,
    encode_ping/1,
    exit_self/1
]).

%% Use OTP's acknowledged suspension rather than guessing when a manager
%% has stopped dequeueing. Always resume, even if the assertion fails.
-spec while_suspended(pid(), fun(() -> A)) -> A.
while_suspended(Pid, Run) ->
    ok = sys:suspend(Pid),
    try
        Run()
    after
        sys:resume(Pid)
    end.

-doc "Build the `{global, Name}` server-ref tuple consumed by `gen_statem`.".
encode_global_target(Name) -> {global, Name}.

-doc "Pass an atom through as an opaque dynamic term.".
encode_atom_as_term(Atom) -> Atom.

-doc """
Build a Gleam `Msg::Ping(reply_with: subject)` value at the Erlang level.
Gleam encodes the `Ping` variant as the tagged tuple `{ping, Subject}`.
""".
encode_ping(ReplySubject) ->
    {ping, ReplySubject}.

-doc "Exit the calling process with an arbitrary reason, such as `shutdown`.".
exit_self(Reason) -> exit(Reason).
