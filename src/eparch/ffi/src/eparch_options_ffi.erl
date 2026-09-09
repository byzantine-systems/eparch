-module(eparch_options_ffi).
-moduledoc """
Shared encoders for the start-option types defined in `eparch/start_options`.
Used by both `statem_ffi` and `event_manager_ffi` so the Gleam-to-Erlang
mapping for `Timeout`, `DebugFlag`, `SpawnOption`, `Priority`, and
`MessageQueueMode` lives in exactly one place.
""".

-export([
    timeout_to_erlang/1,
    debug_to_erlang/1,
    spawn_opt_to_erlang/1,
    priority_to_erlang/1,
    mq_mode_to_erlang/1,
    build_extra_opts/2,
    validate_server_name/1,
    validate_callback_module/1
]).

-define(DEFAULT_MAX_HEAP_WORDS, 8388608).
-define(MAX_TIMEOUT_MS, 4294967295).

-doc "Converts a Gleam `Timeout` to an Erlang `timeout()` value.".
timeout_to_erlang(infinity) ->
    infinity;
timeout_to_erlang({milliseconds, Ms}) when
    is_integer(Ms), Ms >= 0, Ms =< ?MAX_TIMEOUT_MS
->
    Ms.

-doc "Converts a Gleam `DebugFlag` to an Erlang `sys:dbg_opt()` term.".
debug_to_erlang(debug_trace) ->
    trace;
debug_to_erlang(debug_log) ->
    log;
debug_to_erlang(debug_statistics) ->
    statistics;
debug_to_erlang({debug_log_to_file, _FileName}) ->
    %% sys' log_to_file option accepts an arbitrary path and follows links.
    %% A reusable library has no safe directory against which to resolve it.
    erlang:error(debug_log_to_file_disabled).

-doc "Converts a Gleam `SpawnOption` to an Erlang `spawn_opt/2` option.".
spawn_opt_to_erlang({spawn_priority, Level}) ->
    {priority, priority_to_erlang(Level)};
spawn_opt_to_erlang({spawn_fullsweep_after, N}) when is_integer(N), N >= 0 ->
    {fullsweep_after, N};
spawn_opt_to_erlang({spawn_min_heap_size, N}) when is_integer(N), N > 0 ->
    {min_heap_size, N};
spawn_opt_to_erlang({spawn_min_bin_vheap_size, N}) when is_integer(N), N > 0 ->
    {min_bin_vheap_size, N};
spawn_opt_to_erlang({spawn_max_heap_size, N}) when is_integer(N), N > 0 ->
    max_heap_option(N);
spawn_opt_to_erlang({spawn_message_queue_data, Mode}) ->
    {message_queue_data, mq_mode_to_erlang(Mode)}.

-doc "Converts a Gleam `Priority` atom to its Erlang counterpart.".
priority_to_erlang(priority_low) -> low;
priority_to_erlang(priority_normal) -> normal;
priority_to_erlang(priority_high) -> high;
priority_to_erlang(priority_max) -> max.

-doc "Converts a Gleam `MessageQueueMode` atom to its Erlang counterpart.".
mq_mode_to_erlang(on_heap) -> on_heap;
mq_mode_to_erlang(off_heap) -> off_heap.

-doc """
Build the optional `[{debug, _}, {spawn_opt, _}]` tail of a behaviour's
start-option list. Empty lists are skipped so unused options are not present
in the result.
""".
build_extra_opts(DebugFlags, SpawnOpts) ->
    case DebugFlags of
        [] -> [];
        _ -> [{debug, [debug_to_erlang(F) || F <- DebugFlags]}]
    end ++
        [{spawn_opt, build_spawn_opts(SpawnOpts)}].

build_spawn_opts(SpawnOpts) ->
    Converted = lists:map(fun spawn_opt_to_erlang/1, SpawnOpts),
    case lists:keymember(max_heap_size, 1, Converted) of
        true -> Converted;
        false -> [max_heap_option(?DEFAULT_MAX_HEAP_WORDS) | Converted]
    end.

max_heap_option(Words) ->
    {max_heap_size, #{size => Words, kill => true, error_logger => false}}.

validate_server_name({local, Name}) when is_atom(Name) ->
    {local, Name};
validate_server_name({global, Name}) when is_atom(Name) ->
    {global, Name};
validate_server_name({via, Module, Term}) when is_atom(Module) ->
    ok = validate_allowed_module(allowed_registry_modules, Module),
    {via, Module, Term}.

validate_callback_module(Module) when is_atom(Module) ->
    validate_allowed_module(allowed_callback_modules, Module).

validate_allowed_module(Key, Module) ->
    case application:get_env(eparch_ffi, Key, all) of
        all ->
            ok;
        Modules when is_list(Modules) ->
            case lists:member(Module, Modules) of
                true -> ok;
                false -> erlang:error({module_not_allowed, Module})
            end
    end.
