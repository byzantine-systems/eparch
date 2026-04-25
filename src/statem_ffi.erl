-module(statem_ffi).
-moduledoc """
Erlang FFI bridge for the statem Gleam module. Translates between Erlang's
gen_statem behavior callbacks and Gleam's type-safe API.
""".

-behaviour(gen_statem).

%% Public API
-export([do_start/8, cast/2]).
-export([
    reqids_new/0,
    reqids_add/3,
    reqids_size/1,
    reqids_to_list/1,
    send_request/2,
    send_request_to_collection/4,
    receive_response/2,
    receive_response_collection/3
]).

%% gen_statem callbacks
-export([
    init/1,
    callback_mode/0,
    handle_event/4,
    terminate/3,
    code_change/4,
    format_status/1
]).

%%%===================================================================
%%% Internal State Records & Types
%%%===================================================================
-type process_name_option() :: none | {some, Name :: string()}.
-type state_enter_option() :: state_enter_disabled | state_enter_enabled.

-record(gleam_statem, {
    % Current Gleam state value
    gleam_state,
    % Current Gleam data value
    gleam_data,
    % fn(Event, State, Data) -> Step
    gleam_handler,
    % Whether `StateEnter` events reach the Gleam handler
    state_enter,
    % The tag used in this process's Subject:
    % - unnamed: reference (make_ref())
    % - named: atom (the registered name)
    subject_tag,
    % none | {some, fn(data) -> data}
    on_code_change,
    % none | {some, fn(Status) -> Status}
    on_format_status
}).

%%%===================================================================
%%% API
%%% called from Gleam via @external
%%%===================================================================
-doc """
Start a `gen_statem` process linked to the caller and return the Subject
needed to send messages to it
""".
-spec do_start(
    InitialState, InitialData, Handler, StateEnter, TimeOut, Name, OnCodeChange, OnFormatStatus
) ->
    Result
when
    InitialState :: any(),
    InitialData :: any(),
    Handler :: any(),
    StateEnter :: state_enter_option(),
    TimeOut :: timeout(),
    Name :: process_name_option(),
    OnCodeChange :: any(),
    OnFormatStatus :: any(),
    Result :: any().
do_start(
    InitialState, InitialData, Handler, StateEnter, Timeout, Name, OnCodeChange, OnFormatStatus
) ->
    %% Ack channel: a unique reference the child process will use to
    %% send us the Subject it creates in init/1.
    AckTag = make_ref(),
    Parent = self(),

    InitArgs =
        {init_args, InitialState, InitialData, Handler, StateEnter, Parent, AckTag, Name,
            OnCodeChange, OnFormatStatus},

    StartResult =
        case Name of
            none ->
                gen_statem:start_link(?MODULE, InitArgs, [{timeout, Timeout}]);
            {some, ProcessName} ->
                gen_statem:start_link(
                    %% TODO: Change this to support other formats
                    %% https://www.erlang.org/doc/apps/stdlib/gen_statem.html#t:server_name/0
                    {local, ProcessName},
                    ?MODULE,
                    InitArgs,
                    [{timeout, Timeout}]
                )
        end,

    case StartResult of
        {ok, Pid} ->
            %% init/1 runs synchronously inside start_link, so the Subject
            %% is already waiting in our mailbox. Use after 0 as a safety net,
            %% in practice the message is always there.
            receive
                {AckTag, Subject} ->
                    {ok, {started, Pid, Subject}}
            after 0 ->
                %% Should "never" happen, indicates a bug in init/1.
                {error, {init_failed, <<"init/1 did not deliver a Subject">>}}
            end;
        {error, timeout} ->
            {error, init_timeout};
        {error, {already_started, _OtherPid}} ->
            {error, {init_failed, <<"process name already registered">>}};
        {error, Reason} ->
            {error, {init_exited, {abnormal, Reason}}}
    end.

%%%===================================================================
%%% gen_statem callbacks
%%%===================================================================
-doc """
Initialise the gen_statem process.

Creates the Subject for this process and sends it back to the parent
through the ack channel before returning to gen_statem.
""".
init(
    {init_args, InitialState, InitialData, Handler, StateEnter, Parent, AckTag, Name, OnCodeChange,
        OnFormatStatus}
) ->
    %% Build the Subject and determine the tag used for message unwrapping.
    {Subject, SubjectTag} =
        case Name of
            none ->
                %% Unnamed process: tag is a unique reference, subject is the
                %% standard {subject, Pid, Tag} Gleam variant.
                Tag = make_ref(),
                {{subject, self(), Tag}, Tag};
            {some, ProcessName} ->
                %% Named process: tag is the atom, subject is the
                %% {named_subject, Name} Gleam variant.
                {{named_subject, ProcessName}, ProcessName}
        end,

    %% Send the Subject to the parent before gen_statem unblocks start_link.
    Parent ! {AckTag, Subject},

    GleamStatem = #gleam_statem{
        gleam_state = InitialState,
        gleam_data = InitialData,
        gleam_handler = Handler,
        state_enter = StateEnter,
        subject_tag = SubjectTag,
        on_code_change = OnCodeChange,
        on_format_status = OnFormatStatus
    },

    {ok, InitialState, GleamStatem}.

-doc """
Always advertise `handle_event_function` + `state_enter`.

`state_enter` cannot be made conditional here because `callback_mode/0`
is called before `init/1`. The `handle_event/4` guard below filters out
enter events when the user did not opt in.
""".
callback_mode() ->
    [handle_event_function, state_enter].

-doc """
Either drops `enter` events when the user did not opt in to `state_enter`.
Or translates all other events through the Gleam handler.
""".
handle_event(
    enter,
    _OldState,
    _CurrentState,
    #gleam_statem{state_enter = state_enter_disabled} = GleamStatem
) ->
    {keep_state, GleamStatem};
handle_event(
    EventType,
    EventContent,
    State,
    #gleam_statem{
        gleam_handler = Handler,
        gleam_data = Data
    } = GleamStatem
) ->
    GleamEvent = convert_event_to_gleam(
        EventType,
        EventContent,
        State,
        GleamStatem
    ),
    GleamStep = Handler(GleamEvent, State, Data),
    convert_step_to_erlang(GleamStep, GleamStatem).

-doc """
Cleanup on termination.
""".
terminate(_Reason, _State, _GleamStatem) ->
    ok.

-doc """
Hot-code upgrade, calls the user-provided migration function (if set).

When the user calls `statem.on_code_change(builder, fn(data) { ... })`, the
migration function is invoked with the current data and its return value
becomes the new data. If no function was set, the data passes through
unchanged.
""".
code_change(
    _OldVsn,
    State,
    #gleam_statem{
        gleam_data = Data,
        on_code_change = OnCodeChange
    } = GleamStatem,
    _Extra
) ->
    NewData =
        case OnCodeChange of
            none -> Data;
            {some, F} -> F(Data)
        end,
    {ok, State, GleamStatem#gleam_statem{gleam_data = NewData}}.

-doc """
Format the state/data for `sys:get_status/1` and SASL crash reports.

OTP 25+ semantics: receives a status map containing `state`, `data`, and an
optional subset of `reason`, `queue`, `postponed`, `timeouts`, `log`. The
internal `#gleam_statem{}` lives under `data`; we extract the user's
`gleam_data` before calling the Gleam-side formatter, and write the
formatter's returned value back into the map's `data` key unwrapped (the
result is purely for display, never becomes the live process data).

Keys that were absent from the input map are not introduced in the output,
matching OTP's contract that `NewStatus` has the same elements as `Status`.
""".
format_status(
    #{
        state := State,
        data := #gleam_statem{
            on_format_status = OnFormatStatus,
            gleam_data = GleamData,
            subject_tag = SubjectTag
        }
    } = Status
) ->
    case OnFormatStatus of
        none ->
            Status;
        {some, Fun} ->
            Reason = classify_reason_opt(Status),
            Queue = classify_queue_entries(maps:get(queue, Status, []), SubjectTag),
            Postponed = classify_queue_entries(maps:get(postponed, Status, []), SubjectTag),
            Timeouts = classify_timeouts(maps:get(timeouts, Status, [])),
            Log = maps:get(log, Status, []),
            %% Gleam Status record on the Erlang side:
            %% {status, state, data, reason, queue, postponed, timeouts, log}
            GleamStatus =
                {status, State, GleamData, Reason, Queue, Postponed, Timeouts, Log},
            {status, NewState, NewData, NewReason, NewQueue, NewPostponed, NewTimeouts, NewLog} =
                Fun(GleamStatus),
            %% maps:map/2 walks only the keys already in Status, so optional
            %% keys that were absent in the input stay absent in the output,
            %% honouring OTP's "NewStatus has the same elements as Status"
            %% contract. The final clause passes through any future keys OTP
            %% adds to the status map.
            maps:map(
                fun
                    (state, _) ->
                        NewState;
                    (data, _) ->
                        NewData;
                    (reason, OrigReason) ->
                        case NewReason of
                            none -> OrigReason;
                            {some, R} -> unclassify_reason(R)
                        end;
                    (queue, _) ->
                        [unclassify_queue_entry(E) || E <- NewQueue];
                    (postponed, _) ->
                        [unclassify_queue_entry(E) || E <- NewPostponed];
                    (timeouts, _) ->
                        [unclassify_timeout(T) || T <- NewTimeouts];
                    (log, _) ->
                        NewLog;
                    (_, V) ->
                        V
                end,
                Status
            )
    end.

%%%===================================================================
%%% format_status: Erlang <-> Gleam conversions
%%%
%%% All classify_* converters aim for typed Gleam variants; any shape
%%% we cannot confidently map is wrapped in an *_other variant carrying
%%% the raw term, so format_status never crashes on unexpected input.
%%%===================================================================

classify_reason_opt(Status) ->
    case maps:find(reason, Status) of
        {ok, R} -> {some, classify_reason(R)};
        error -> none
    end.

%% Gleam process.ExitReason is {normal} | {killed} | {abnormal, Term}.
%% Wrap recognised shapes as Exit(...); everything else as RawReason(term).
classify_reason(normal) -> {exit, {normal}};
classify_reason(killed) -> {exit, {killed}};
classify_reason({abnormal, T}) -> {exit, {abnormal, T}};
classify_reason(Other) -> {raw_reason, Other}.

unclassify_reason({exit, {normal}}) -> normal;
unclassify_reason({exit, {killed}}) -> killed;
unclassify_reason({exit, {abnormal, T}}) -> {abnormal, T};
unclassify_reason({raw_reason, Term}) -> Term.

classify_queue_entries(Entries, SubjectTag) ->
    [classify_queue_entry(E, SubjectTag) || E <- Entries].

classify_queue_entry({{call, From}, Content}, _) ->
    {queued_call, From, Content};
classify_queue_entry({cast, Content}, _) ->
    {queued_cast, Content};
classify_queue_entry({info, Content}, SubjectTag) ->
    %% Match handle_event/4's behaviour: unwrap messages sent via the Subject,
    %% pass through raw Erlang terms unchanged.
    Msg =
        case Content of
            {SubjectTag, M} -> M;
            _ -> Content
        end,
    {queued_info, Msg};
classify_queue_entry({internal, Content}, _) ->
    {queued_internal, Content};
classify_queue_entry({state_timeout, Content}, _) ->
    {queued_state_timeout, Content};
classify_queue_entry({{timeout, Name}, Content}, _) when is_binary(Name) ->
    {queued_generic_timeout, Name, Content};
classify_queue_entry(Other, _) ->
    {queued_other, Other}.

unclassify_queue_entry({queued_call, From, Content}) -> {{call, From}, Content};
unclassify_queue_entry({queued_cast, Content}) -> {cast, Content};
unclassify_queue_entry({queued_info, Msg}) -> {info, Msg};
unclassify_queue_entry({queued_internal, Content}) -> {internal, Content};
unclassify_queue_entry({queued_state_timeout, Content}) -> {state_timeout, Content};
unclassify_queue_entry({queued_generic_timeout, Name, Content}) -> {{timeout, Name}, Content};
unclassify_queue_entry({queued_other, Raw}) -> Raw.

classify_timeouts(Entries) ->
    [classify_timeout(E) || E <- Entries].

classify_timeout({state_timeout, Content}) ->
    {active_state_timeout, Content};
classify_timeout({{timeout, Name}, Content}) when is_binary(Name) ->
    {active_generic_timeout, Name, Content};
classify_timeout(Other) ->
    {active_other_timeout, Other}.

unclassify_timeout({active_state_timeout, Content}) -> {state_timeout, Content};
unclassify_timeout({active_generic_timeout, Name, Content}) -> {{timeout, Name}, Content};
unclassify_timeout({active_other_timeout, Raw}) -> Raw.

%%%===================================================================
%%% Event conversion from Erlang to Gleam
%%%===================================================================

-doc """
Converts a `gen_statem` event into the Gleam Event union type.

Info events are unwrapped: if the first element of the message tuple
matches the Subject tag stored in `#gleam_statem`, the wrapper is
stripped so the Gleam handler receives `Info(Msg)` rather than
`Info({Tag, Msg})`.
""".
convert_event_to_gleam(EventType, EventContent, _State, GleamStatem) ->
    case EventType of
        {call, From} ->
            %% Synchronous gen_statem call (Erlang interop).
            %% Gleam: Call(from: From(reply), message: msg)
            %% From is an external type, passed through as-is.
            {call, From, EventContent};
        cast ->
            %% Asynchronous gen_statem cast (Erlang interop).
            %% Gleam: Cast(message: msg)
            {cast, EventContent};
        info ->
            %% Messages delivered to this process's mailbox.
            %% Unwrap if sent via our Subject (process.send).
            SubjectTag = GleamStatem#gleam_statem.subject_tag,
            case EventContent of
                {SubjectTag, Msg} ->
                    %% Message was sent via process.send(subject, Msg).
                    {info, Msg};
                Other ->
                    %% Raw Erlang message (monitor signals, raw sends, etc.).
                    {info, Other}
            end;
        enter ->
            %% State-entry callback: EventContent is the previous state.
            %% Gleam: Enter(old_state: state)
            {enter, EventContent};
        state_timeout ->
            %% State timeout fired.
            %% Gleam: Timeout(StateTimeoutType)
            {timeout, state_timeout_type};
        {timeout, Name} ->
            %% Named generic timeout fired.
            %% Gleam: Timeout(GenericTimeoutType(name))
            {timeout, {generic_timeout_type, Name}};
        internal ->
            %% Internal events are fired by the NextEvent action.
            %% Map to Cast so the user pattern-matches them as Cast(msg).
            {cast, EventContent};
        _Other ->
            %% Truly unknown event type, wrap as Info so the user can handle
            %% or ignore it in their catch-all clause.
            {info, {unexpected_event, EventType, EventContent}}
    end.

%%%===================================================================
%%% Step conversion
%%% Gleam to Erlang
%%%===================================================================

-doc """
Converts a Gleam Step back to the `gen_statem` result tuple format.
""".
convert_step_to_erlang(GleamStep, GleamStatem) ->
    case GleamStep of
        {next_state, NewState, NewData, GleamActions} ->
            Actions = convert_actions_to_erlang(GleamActions),
            NewGleamStatem = GleamStatem#gleam_statem{
                gleam_state = NewState,
                gleam_data = NewData
            },
            case Actions of
                [] -> {next_state, NewState, NewGleamStatem};
                _ -> {next_state, NewState, NewGleamStatem, Actions}
            end;
        {keep_state, NewData, GleamActions} ->
            Actions = convert_actions_to_erlang(GleamActions),
            NewGleamStatem = GleamStatem#gleam_statem{
                gleam_data = NewData
            },
            case Actions of
                [] -> {keep_state, NewGleamStatem};
                _ -> {keep_state, NewGleamStatem, Actions}
            end;
        {stop, Reason} ->
            {stop, convert_exit_reason(Reason)}
    end.

convert_actions_to_erlang(GleamActions) ->
    lists:map(fun convert_action_to_erlang/1, GleamActions).

convert_action_to_erlang(Action) ->
    case Action of
        {reply, From, Response} ->
            %% Reply to a gen_statem:call caller.
            %% From is the external type, the raw gen_statem:from() term.
            {reply, From, Response};
        postpone ->
            postpone;
        {next_event, Content} ->
            {next_event, internal, Content};
        {state_timeout, Milliseconds} ->
            {state_timeout, Milliseconds, timeout};
        {generic_timeout, Name, Milliseconds} ->
            {{timeout, Name}, Milliseconds, timeout};
        {change_callback_module, Module} ->
            {change_callback_module, Module};
        {push_callback_module, Module} ->
            {push_callback_module, Module};
        pop_callback_module ->
            pop_callback_module
    end.

-doc """
Sends an asynchronous `cast` to a running `gen_statem` process.

Extracts the `Pid` from the Gleam Subject and calls `gen_statem:cast/2`.
The message arrives in `handle_event/4` with `EventType=cast` and is
converted to `Cast(Msg)` for the Gleam handler.
""".
cast(Subject, Msg) ->
    Pid =
        case Subject of
            {subject, P, _Tag} ->
                P;
            {named_subject, Name} ->
                case erlang:whereis(Name) of
                    P when is_pid(P) -> P;
                    undefined -> error({noproc, Name})
                end
        end,
    gen_statem:cast(Pid, Msg),
    nil.

%%%===================================================================
%%% reqids API — OTP 25.0+
%%%===================================================================

-doc "Creates a new empty request-id collection.".
reqids_new() ->
    gen_statem:reqids_new().

-doc "Adds a request id to a collection under the given label.".
reqids_add(ReqId, Label, Collection) ->
    gen_statem:reqids_add(ReqId, Label, Collection).

-doc "Returns the number of request ids in the collection.".
reqids_size(Collection) ->
    gen_statem:reqids_size(Collection).

-doc "Converts the collection to a list of {ReqId, Label} pairs.".
reqids_to_list(Collection) ->
    gen_statem:reqids_to_list(Collection).

-doc """
Sends an asynchronous call request to a gen_statem process and returns a
request id. The server receives a `Call(from, msg)` event and must respond
with a `Reply(from, value)` action. Use `receive_response/2` to collect the
reply when ready.
""".
send_request({subject, Pid, _Tag}, Msg) ->
    gen_statem:send_request(Pid, Msg);
send_request({named_subject, Name}, Msg) ->
    case erlang:whereis(Name) of
        Pid when is_pid(Pid) -> gen_statem:send_request(Pid, Msg);
        undefined -> error({noproc, Name})
    end.

-doc """
Like `send_request/2` but also adds the resulting request id (under `Label`)
to `Collection`, returning the updated collection.
""".
send_request_to_collection({subject, Pid, _Tag}, Msg, Label, Collection) ->
    gen_statem:send_request(Pid, Msg, Label, Collection);
send_request_to_collection({named_subject, Name}, Msg, Label, Collection) ->
    case erlang:whereis(Name) of
        Pid when is_pid(Pid) -> gen_statem:send_request(Pid, Msg, Label, Collection);
        undefined -> error({noproc, Name})
    end.

-doc """
Waits up to `Timeout` milliseconds for the reply to a single `ReqId`.
Returns `{ok, Reply}` on success, `{error, receive_timeout}` on timeout,
or `{error, {request_crashed, StopReason}}` if the server terminated.
""".
receive_response(ReqId, Timeout) ->
    case gen_statem:receive_response(ReqId, Timeout) of
        {reply, Reply} ->
            {ok, Reply};
        timeout ->
            {error, receive_timeout};
        {error, {Reason, _ServerRef}} ->
            {error, {request_crashed, classify_reason(Reason)}}
    end.

-doc """
Waits up to `Timeout` milliseconds for any reply in `Collection`.
`Handling` is the atom `delete` (remove the matched request from the
returned collection) or `keep`. Maps to Gleam's `CollectionResponse`
constructors:
  `{got_reply, Reply, Label, NewColl}`
  `{request_failed, StopReason, Label, NewColl}`
  `no_requests`
""".
receive_response_collection(Collection, Timeout, Handling) ->
    Delete =
        case Handling of
            delete -> true;
            keep -> false
        end,
    case gen_statem:receive_response(Collection, Timeout, Delete) of
        {{reply, Reply}, Label, NewColl} ->
            {got_reply, Reply, Label, NewColl};
        {{error, {Reason, _ServerRef}}, Label, NewColl} ->
            {request_failed, classify_reason(Reason), Label, NewColl};
        no_request ->
            no_requests
    end.

-doc """
Converts a Gleam ExitReason to an Erlang exit reason term.
""".
convert_exit_reason(Reason) ->
    case Reason of
        {normal} -> normal;
        {killed} -> killed;
        {abnormal, Term} -> {abnormal, Term};
        _ -> Reason
    end.
