-module(eparch_workload_ffi).
-moduledoc """
Native helpers for the workload scenarios in `dev/eparch/workload`.

Callback receipts are written to an ETS table synchronously, so a receipt
inserted before a handler acknowledges is visible to the publisher as soon
as its confirmation returns. Message passing alone gives no such guarantee
across three processes.
""".
-export([new_receipts/0, record/3, trace/2, mailbox_length/0, plain_arguments/0, halt/1]).

-doc "Create an anonymous, public, ordered receipt table owned by the caller.".
-spec new_receipts() -> ets:tid().
new_receipts() ->
    ets:new(eparch_workload_receipts, [ordered_set, public]).

-doc "Record that `Role` handled `Event`, ordered by a monotonic sequence.".
-spec record(ets:tid(), early | late, term()) -> nil.
record(Table, Role, Event) ->
    true = ets:insert(Table, {erlang:unique_integer([monotonic]), Role, Event}),
    nil.

-doc "Every event `Role` handled, in handling order.".
-spec trace(ets:tid(), early | late) -> [term()].
trace(Table, Role) ->
    [Event || {_, R, Event} <- ets:tab2list(Table), R =:= Role].

-doc "Number of messages waiting in the calling process's mailbox.".
-spec mailbox_length() -> non_neg_integer().
mailbox_length() ->
    {message_queue_len, Length} = process_info(self(), message_queue_len),
    Length.

-doc "Command-line arguments after `-extra`, as Gleam strings.".
-spec plain_arguments() -> [binary()].
plain_arguments() ->
    [unicode:characters_to_binary(Arg) || Arg <- init:get_plain_arguments()].

-doc "Stop the node with the given status once output is flushed.".
-spec halt(non_neg_integer()) -> no_return().
halt(Status) ->
    erlang:halt(Status, [{flush, true}]).
