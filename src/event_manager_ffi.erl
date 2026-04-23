-module(event_manager_ffi).
-moduledoc """
Erlang FFI bridge for the event_manager Gleam module.

This module serves a dual role:

  1. **API layer**: functions called from Gleam via @external(erlang, ...).
  2. **gen_event handler module**: implements the gen_event handler callbacks
     so that Gleam-defined handlers can be registered with a gen_event manager
     via `gen_event:add_handler(Mgr, {event_manager_ffi, Ref}, Args)`.

Each Gleam handler is stored in the gen_event handler state as a
`#gleam_handler{}` record.  The unique `Ref` (an Erlang reference) forms the
second element of the handler identifier `{event_manager_ffi, Ref}`, making
every installed instance distinguishable.
""".

-behaviour(gen_event).

%% Public API (called from Gleam via @external)
-export([
    do_start/0,
    do_start_monitor/1,
    do_stop/1,
    do_manager_pid/1,
    do_add_handler/2,
    do_add_sup_handler/2,
    do_remove_handler/2,
    do_which_handlers/1,
    do_notify/2,
    do_sync_notify/2
]).

%% gen_event handler callbacks
-export([
    init/1,
    handle_event/2,
    handle_info/2,
    handle_call/2,
    terminate/2,
    code_change/3,
    format_status/1
]).

%%%===================================================================
%%% Internal handler state
%%%===================================================================
-record(gleam_handler, {
    % The unique reference part of {event_manager_ffi, Ref}
    ref,
    % User's current Gleam state value
    gleam_state,
    % fn(event, state) -> EventStep
    on_event,
    % none | {some, fn(state) -> nil}
    on_terminate,
    % none | {some, fn(state) -> binary()}
    on_format_status
}).

%%%===================================================================
%%% API
%%% called from Gleam via @external
%%%===================================================================

-doc """
Start a `gen_event` manager linked to the calling process.

Returns a `Manager(event)` value, which at the Erlang level is just 
the Pid of the manager process.
""".
do_start() ->
    case gen_event:start_link() of
        {ok, Pid} ->
            {ok, Pid};
        {error, {already_started, Pid}} ->
            {error, {already_started, Pid}};
        {error, Reason} ->
            {error, {start_failed, format_reason(Reason)}}
    end.

-doc """
Start a gen_event manager with an atomic monitor (OTP 23.0+).

The Gleam side passes an opaque `StartOptions` record, encoded at the Erlang
level as:

    {start_options, NameOpt, Timeout, HibernateAfter, DebugFlags, SpawnOpts}

`NameOpt` is `none | {some, Name}`; `Timeout`/`HibernateAfter` are
`infinity | {milliseconds, Ms}`; the two list fields are empty when unused.
Returns the `MonitoredManager(manager, monitor)` 3-tuple the Gleam compiler
expects.
""".
do_start_monitor({start_options, NameOpt, Timeout, HibernateAfter, DebugFlags, SpawnOpts}) ->
    ErlangOpts = build_start_opts(Timeout, HibernateAfter, DebugFlags, SpawnOpts),
    Result =
        case NameOpt of
            none ->
                gen_event:start_monitor(ErlangOpts);
            {some, Name} ->
                gen_event:start_monitor({local, Name}, ErlangOpts)
        end,
    case Result of
        {ok, {Pid, MonitorRef}} ->
            {ok, {monitored_manager, Pid, MonitorRef}};
        {error, {already_started, Pid}} ->
            {error, {already_started, Pid}};
        {error, Reason} ->
            {error, {start_failed, format_reason(Reason)}}
    end.

build_start_opts(Timeout, HibernateAfter, DebugFlags, SpawnOpts) ->
    [{timeout, timeout_to_erlang(Timeout)}, {hibernate_after, timeout_to_erlang(HibernateAfter)}] ++
        case DebugFlags of
            [] -> [];
            _ -> [{debug, [debug_to_erlang(F) || F <- DebugFlags]}]
        end ++
        case SpawnOpts of
            [] -> [];
            _ -> [{spawn_opt, [spawn_opt_to_erlang(O) || O <- SpawnOpts]}]
        end.

timeout_to_erlang(infinity) -> infinity;
timeout_to_erlang({milliseconds, Ms}) -> Ms.

debug_to_erlang(debug_trace) -> trace;
debug_to_erlang(debug_log) -> log;
debug_to_erlang(debug_statistics) -> statistics;
debug_to_erlang({debug_log_to_file, FileName}) -> {log_to_file, FileName}.

spawn_opt_to_erlang({spawn_priority, Level}) ->
    {priority, priority_to_erlang(Level)};
spawn_opt_to_erlang({spawn_fullsweep_after, N}) ->
    {fullsweep_after, N};
spawn_opt_to_erlang({spawn_min_heap_size, N}) ->
    {min_heap_size, N};
spawn_opt_to_erlang({spawn_min_bin_vheap_size, N}) ->
    {min_bin_vheap_size, N};
spawn_opt_to_erlang({spawn_max_heap_size, N}) ->
    {max_heap_size, N};
spawn_opt_to_erlang({spawn_message_queue_data, Mode}) ->
    {message_queue_data, mq_mode_to_erlang(Mode)}.

%% Render an Erlang error term as a human-readable Gleam string.
format_reason(Reason) ->
    unicode:characters_to_binary(io_lib:format("~p", [Reason])).

priority_to_erlang(priority_low) -> low;
priority_to_erlang(priority_normal) -> normal;
priority_to_erlang(priority_high) -> high;
priority_to_erlang(priority_max) -> max.

mq_mode_to_erlang(on_heap) -> on_heap;
mq_mode_to_erlang(off_heap) -> off_heap.

-doc """
Stop the event manager, terminating it with reason `normal`.

All registered handlers have their `terminate/2` callback invoked.
""".
do_stop(Pid) ->
    gen_event:stop(Pid),
    nil.

-doc """
Return the Pid of the event manager process.

At the Erlang level `Manager(event)` is already a Pid, so this is a no-op.
""".
do_manager_pid(Pid) ->
    Pid.

-doc """
Register an unsupervised Gleam handler with the manager.

Generates a unique reference, packages the Gleam handler record into
`{event_manager_ffi, Ref}`, and calls `gen_event:add_handler/3`.
Returns `{ok, HandlerRef}` or a mapped error.
""".
do_add_handler(Pid, GleamHandler) ->
    Ref = make_ref(),
    HandlerId = {event_manager_ffi, Ref},
    case gen_event:add_handler(Pid, HandlerId, {GleamHandler, Ref}) of
        ok ->
            {ok, HandlerId};
        {'EXIT', Reason} ->
            {error, {init_failed, format_reason(Reason)}};
        {error, already_started} ->
            {error, {handler_already_exists, HandlerId}};
        {error, Reason} ->
            {error, {init_failed, format_reason(Reason)}}
    end.

-doc """
Register a supervised Gleam handler with the manager.

Like `do_add_handler/2` but uses `gen_event:add_sup_handler/3`, which links
the handler to the calling process.  If the handler is removed unexpectedly,
a `{gen_event_EXIT, HandlerId, Reason}` message is sent to the caller.
""".
do_add_sup_handler(Pid, GleamHandler) ->
    Ref = make_ref(),
    HandlerId = {event_manager_ffi, Ref},
    case gen_event:add_sup_handler(Pid, HandlerId, {GleamHandler, Ref}) of
        ok ->
            {ok, HandlerId};
        {'EXIT', Reason} ->
            {error, {init_failed, format_reason(Reason)}};
        {error, already_started} ->
            {error, {handler_already_exists, HandlerId}};
        {error, Reason} ->
            {error, {init_failed, format_reason(Reason)}}
    end.

-doc """
Remove a specific handler identified by its `HandlerRef`.

Calls `gen_event:delete_handler/3`; the handler's `terminate/2` is invoked
with reason `{stop, remove_handler}`.
""".
do_remove_handler(Pid, HandlerId) ->
    case gen_event:delete_handler(Pid, HandlerId, remove_handler) of
        {error, module_not_found} ->
            {error, {handler_not_found, HandlerId}};
        {'EXIT', Reason} ->
            {error, {remove_failed, format_reason(Reason)}};
        _TerminateResult ->
            %% Any other value is what the handler's terminate/2 returned
            %% (which we treat as a successful removal).
            {ok, nil}
    end.

-doc """
Return the list of handler identifiers (HandlerRef values) currently
registered with the manager.

Filters to only those installed by this FFI module.
""".
do_which_handlers(Pid) ->
    Handlers = gen_event:which_handlers(Pid),
    [H || {event_manager_ffi, _} = H <- Handlers].

-doc """
Asynchronously broadcast an event to all registered handlers.

Wraps `gen_event:notify/2`.  Returns immediately.
""".
do_notify(Pid, Event) ->
    gen_event:notify(Pid, Event),
    nil.

-doc """
Synchronously broadcast an event to all registered handlers.

Wraps `gen_event:sync_notify/2`.  Blocks until every handler has processed
the event.
""".
do_sync_notify(Pid, Event) ->
    gen_event:sync_notify(Pid, Event),
    nil.

%%%===================================================================
%%% gen_event handler callbacks
%%%===================================================================

-doc """
Initialise a handler instance from the Gleam Handler builder record.

The Gleam `Handler(state, event)` opaque type is represented at the Erlang
level as a 5-tuple:

    {handler, InitState, OnEvent, OnTerminate, OnFormatStatus}

We unpack it here and store the fields alongside the unique Ref in a
`#gleam_handler{}` record.
""".
init({{handler, InitState, OnEvent, OnTerminate, OnFormatStatus}, Ref}) ->
    State = #gleam_handler{
        ref = Ref,
        gleam_state = InitState,
        on_event = OnEvent,
        on_terminate = OnTerminate,
        on_format_status = OnFormatStatus
    },
    {ok, State}.

-doc """
Deliver an event dispatched via `notify` or `sync_notify` to the Gleam handler.

Calls `OnEvent(Event, GleamState)` and converts the returned `EventStep`:
- `{continue, NewState}` -> `{ok, UpdatedRecord}` (keep the handler)
- `remove` -> `remove_handler`
""".
handle_event(Event, #gleam_handler{on_event = OnEvent, gleam_state = GleamState} = State) ->
    case OnEvent(Event, GleamState) of
        {continue, NewState} ->
            {ok, State#gleam_handler{gleam_state = NewState}};
        remove ->
            remove_handler
    end.

-doc """
Handle messages delivered directly to the manager's mailbox (not via
`notify`/`sync_notify`).

Uses the same `on_event` callback as `handle_event/2`.
""".
handle_info(Info, #gleam_handler{on_event = OnEvent, gleam_state = GleamState} = State) ->
    case OnEvent(Info, GleamState) of
        {continue, NewState} ->
            {ok, State#gleam_handler{gleam_state = NewState}};
        remove ->
            remove_handler
    end.

-doc """
Synchronous call to a specific handler via `gen_event:call/3,4`.

Not exposed in the Gleam API (users embed `Subject(reply)` in their event type
instead), but must be implemented to satisfy the gen_event behaviour.
""".
handle_call(_Request, State) ->
    {ok, {error, not_supported}, State}.

-doc """
Handler teardown.

Calls the optional `on_terminate` Gleam function with the final state if one
was registered.
""".
terminate(_Reason, #gleam_handler{on_terminate = OnTerminate, gleam_state = GleamState}) ->
    case OnTerminate of
        none ->
            ok;
        {some, F} ->
            F(GleamState),
            ok
    end.

-doc """
Hot-code upgrade support (pass-through).
""".
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

-doc """
Format the handler state for `sys:get_status/1` and SASL crash reports.

OTP 25+ semantics: receives a status map containing `state` (the handler's
internal record) plus optional `message`, `reason`, and `log` keys. Returns
the same map, optionally with `state` replaced by the user-supplied
formatter's output. When no `on_format_status` was registered, the map is
returned unchanged.
""".
format_status(
    #{
        state := #gleam_handler{
            on_format_status = OnFormatStatus,
            gleam_state = GleamState
        }
    } = Status
) ->
    case OnFormatStatus of
        none ->
            Status;
        {some, Fun} ->
            Status#{state => Fun(GleamState)}
    end.
