-module(eparch_delivery_ffi).
-moduledoc "Native mailbox operations for the event manager.".
-export([notify_observer/2, request/3, respond/2, now_ms/0]).

-spec now_ms() -> integer().
now_ms() -> erlang:monotonic_time(millisecond).

%% OTP 24+ process aliases separate the caller's wait from the work. The
%% request is sent by the original caller (preserves same-sender FIFO).
-spec request(pid(), integer(), fun((reference(), integer()) -> nil)) ->
    {ok, term()} | {error, wait_timeout | wait_down}.
request(Pid, Timeout, Send) ->
    Deadline = now_ms() + min(16#ffffffff, max(0, Timeout)),
    Ref = monitor(process, Pid, [{alias, demonitor}]),
    try
        Send(Ref, Deadline),
        receive
            {Ref, Value} -> {ok, Value};
            {'DOWN', Ref, process, Pid, _} -> {error, wait_down}
        after max(0, Deadline - now_ms()) -> {error, wait_timeout}
        end
    after
        demonitor(Ref, [flush]),
        %% Deactivation drops future sends; discard a reply already queued.
        receive
            {Ref, _} -> ok
        after 0 -> ok
        end
    end.

-spec respond(reference(), term()) -> nil.
respond(Ref, Value) ->
    Ref ! {Ref, Value},
    nil.

%% A named observer can disappear at any time. Resolve once, then send to
%% that pid; a subsequent exit drops the message without raising badarg.
-spec notify_observer(tuple(), term()) -> nil.
notify_observer({named_subject, Name}, Event) ->
    _ =
        case whereis(Name) of
            Pid when is_pid(Pid) -> Pid ! {Name, Event};
            _ -> ok
        end,
    nil;
notify_observer({subject, Pid, Tag}, Event) ->
    Pid ! {Tag, Event},
    nil.
