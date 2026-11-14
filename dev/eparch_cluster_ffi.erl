-module(eparch_cluster_ffi).
-moduledoc """
Distribution helpers for the cluster workload (OTP 25+).

`run/2` starts three `peer` nodes: a client and hosts `a` and `b`. The
origin drives the client over standard I/O and never joins the cluster.

Peer settings:

- Loopback only, for distribution and EPMD.
- `-nocookie`, then a random cookie set over standard I/O, so it never
  appears on a command line.
- `dist_auto_connect never`: partitions last until `heal/1`.
- `prevent_overlapping_partitions false`: otherwise `global`, unable to
  mesh `a` with `b`, drops the client's connections.

Each run creates four internal atoms: three node names and the cookie.
""".
-export([
    run/2,
    remote/3,
    isolate/1,
    heal/1,
    disconnect_all/0,
    kill_and_wait/1,
    global_whereis/1,
    new_ledger/0,
    ledger_record/2,
    ledger_ids/1
]).

-define(WAIT_MS, 5000).

-doc """
Run `Client(A, B)` on a fresh cluster, then stop it. A client exception
or timeout becomes `{error, Description}`, reported as a violation. A
peer that fails to start crashes the caller.
""".
-spec run(fun((node(), node()) -> T), non_neg_integer()) -> {ok, T} | {error, binary()}.
run(Client, Timeout) ->
    Cookie = binary_to_atom(base64:encode(crypto:strong_rand_bytes(18))),
    Tag = integer_to_list(erlang:unique_integer([positive])) ++ "_" ++ os:getpid(),
    {PeerC, _} = start_peer("eparch_c_" ++ Tag, Cookie),
    {PeerA, A} = start_peer("eparch_a_" ++ Tag, Cookie),
    {PeerB, B} = start_peer("eparch_b_" ++ Tag, Cookie),
    try peer:call(PeerC, erlang, apply, [Client, [A, B]], Timeout) of
        Result -> {ok, Result}
    catch
        Class:Reason when Class =:= error; Class =:= exit ->
            {error, unicode:characters_to_binary(io_lib:format("~p:~0p", [Class, Reason]))}
    after
        lists:foreach(fun peer:stop/1, [PeerC, PeerA, PeerB])
    end.

start_peer(Name, Cookie) ->
    {ok, Peer, Node} = peer:start(#{
        name => Name,
        host => "localhost",
        connection => standard_io,
        env => [{"ERL_EPMD_ADDRESS", "127.0.0.1"}],
        args => [
            "-nocookie",
            "-kernel",
            "dist_auto_connect",
            "never",
            "-kernel",
            "inet_dist_use_interface",
            "{127,0,0,1}",
            "-kernel",
            "prevent_overlapping_partitions",
            "false",
            "-kernel",
            "logger_level",
            "error",
            "-pa"
            | code_paths()
        ]
    }),
    true = peer:call(Peer, erlang, set_cookie, [Cookie]),
    {Peer, Node}.

%% The origin's non-OTP code paths: eparch and its dependencies.
code_paths() ->
    Otp = code:lib_dir(),
    [Path || Path <- code:get_path(), not lists:prefix(Otp, Path)].

-doc """
Run `Fun` on `Node`. `erpc` failures (unreachable, timeout) become
`{error, nil}`; exceptions from `Fun` propagate as workload bugs.
""".
-spec remote(node(), fun(() -> T), non_neg_integer()) -> {ok, T} | {error, nil}.
remote(Node, Fun, Timeout) ->
    try erpc:call(Node, Fun, Timeout) of
        Result -> {ok, Result}
    catch
        error:{erpc, _} -> {error, nil}
    end.

-doc """
Disconnect `Node` from all its peers and wait until the caller sees it go.
Returns `false` on timeout.
""".
-spec isolate(node()) -> boolean().
isolate(Node) ->
    true = erlang:monitor_node(Node, true),
    ok = erpc:cast(Node, ?MODULE, disconnect_all, []),
    receive
        {nodedown, Node} -> true
    after ?WAIT_MS ->
        true = erlang:monitor_node(Node, false),
        receive
            {nodedown, Node} -> true
        after 0 -> false
        end
    end.

-doc "Disconnect the calling node from all its peers.".
-spec disconnect_all() -> nil.
disconnect_all() ->
    lists:foreach(fun erlang:disconnect_node/1, nodes()),
    nil.

-doc """
Connect to every node in `Nodes`, then `global:sync/0`. Returns whether
all of it succeeded.
""".
-spec heal([node()]) -> boolean().
heal(Nodes) ->
    Connected = [net_kernel:connect_node(Node) || Node <- Nodes],
    Synced = global:sync(),
    lists:all(fun(Result) -> Result =:= true end, Connected) andalso Synced =:= ok.

-doc """
Kill `Pid` and wait for its `DOWN`. Returns `false` on timeout.
""".
-spec kill_and_wait(pid()) -> boolean().
kill_and_wait(Pid) ->
    Ref = monitor(process, Pid),
    true = exit(Pid, kill),
    receive
        {'DOWN', Ref, process, Pid, _} -> true
    after ?WAIT_MS ->
        true = demonitor(Ref, [flush]),
        false
    end.

-doc "The pid `global` currently resolves `Name` to.".
-spec global_whereis(atom()) -> {ok, pid()} | {error, nil}.
global_whereis(Name) ->
    case global:whereis_name(Name) of
        undefined -> {error, nil};
        Pid when is_pid(Pid) -> {ok, Pid}
    end.

-doc """
Create a public ETS ledger on the calling node. An unlinked owner keeps it
alive across server restarts until the peer stops. The id is node-local.
""".
-spec new_ledger() -> ets:tid().
new_ledger() ->
    Parent = self(),
    Ref = make_ref(),
    _ = spawn(fun() ->
        Table = ets:new(eparch_cluster_ledger, [bag, public]),
        Parent ! {Ref, Table},
        receive
            {Ref, stop} -> ok
        end
    end),
    receive
        {Ref, Table} -> Table
    after ?WAIT_MS -> error(ledger_owner_unresponsive)
    end.

-doc "Record that a call with `Id` took effect.".
-spec ledger_record(ets:tid(), integer()) -> nil.
ledger_record(Table, Id) ->
    true = ets:insert(Table, {Id}),
    nil.

-doc "Every recorded id, with duplicates, in ascending order.".
-spec ledger_ids(ets:tid()) -> [integer()].
ledger_ids(Table) ->
    lists:sort([Id || {Id} <- ets:tab2list(Table)]).
