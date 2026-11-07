-module(eparch_delivery_ffi).
-moduledoc "Native mailbox operations for the event manager.".
-export([notify_observer/2]).

%% A named observer can disappear at any time. Resolve once, then send to
%% that pid; a subsequent exit drops the message without raising badarg.
-spec notify_observer(tuple(), term()) -> nil.
notify_observer({named_subject, Name}, Event) ->
    case whereis(Name) of
        Pid when is_pid(Pid) -> Pid ! {Name, Event};
        _ -> ok
    end,
    nil;
notify_observer({subject, Pid, Tag}, Event) ->
    Pid ! {Tag, Event},
    nil.
