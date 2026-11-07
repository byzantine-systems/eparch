%% Workload client of the public Gleam module (OTP 27+ for json:encode/1).
%% No manager mailbox messages, registry inspection or opaque ref unpacking.
-module(probe).
-export([run/0]).
-define(M, eparch@event_manager).
-define(WAIT, 10000).

-spec run() -> ok.
run() ->
    [Arg] = init:get_plain_arguments(),
    N = list_to_integer(Arg),
    true = N >= 1 andalso N =< 16,
    T = ets:new(callbacks, [ordered_set, public]),
    Options = ?M:with_max_in_flight_sync(?M:new_start_options(), 1),
    {ok, M} = ?M:start_link(Options),
    Parent = self(),
    Ref = make_ref(),
    add(M, early, T, Parent, Ref),
    spawn_link(fun() ->
        lists:foreach(fun(I) -> ?M:notify(M, I) end, lists:seq(1, N)),
        Result = ?M:sync_notify(M, gate, ?WAIT),
        Parent ! {Ref, first, outcome(Result), trace(T, early)}
    end),
    Gate =
        receive
            {Ref, entered, Pid} -> Pid
        after ?WAIT -> error(no_gate)
        end,
    %% Callback entry witnesses acceptance. This registration cannot precede it.
    add(M, late, T, Parent, Ref),
    Pressure = outcome(?M:sync_notify(M, pressure, ?WAIT)),
    Gate ! {Ref, release},
    {First, AtReturn} =
        receive
            {Ref, first, F, A} -> {F, A}
        after ?WAIT -> error(no_first_result)
        end,
    Final = outcome(?M:sync_notify(M, fence, ?WAIT)),
    Report = #{
        n => N,
        first => First,
        at_return => AtReturn,
        pressure => Pressure,
        final => Final,
        early => trace(T, early),
        late => trace(T, late)
    },
    io:format("EPARCH ~s~n", [json:encode(Report)]),
    ?M:stop(M, ?WAIT),
    ok.

add(M, Role, T, Parent, Ref) ->
    Handler = ?M:new_handler(nil, fun(Event, State) ->
        case {Role, Event} of
            {early, gate} ->
                Parent ! {Ref, entered, self()},
                receive
                    {Ref, release} -> ok
                after 4 * ?WAIT -> error(gate_stuck)
                end;
            _ ->
                ok
        end,
        ets:insert(T, {erlang:unique_integer([monotonic]), Role, Event}),
        {continue, State}
    end),
    {ok, _} = ?M:add_handler(M, Handler, none).

trace(T, Role) -> [E || {_, H, E} <- ets:tab2list(T), H =:= Role].

outcome({unconfirmed, _Ids}) -> unconfirmed;
outcome(Atom) when is_atom(Atom) -> Atom.
