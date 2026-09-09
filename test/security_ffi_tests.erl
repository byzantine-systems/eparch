-module(security_ffi_tests).

-include_lib("eunit/include/eunit.hrl").

invalid_timeout_is_rejected_test() ->
    ?assertError(function_clause, eparch_options_ffi:timeout_to_erlang({milliseconds, -1})),
    ?assertError(function_clause, eparch_options_ffi:timeout_to_erlang({milliseconds, 4294967296})).

invalid_spawn_option_is_rejected_test() ->
    ?assertError(function_clause, eparch_options_ffi:spawn_opt_to_erlang({spawn_max_heap_size, 0})),
    ?assertError(
        function_clause, eparch_options_ffi:spawn_opt_to_erlang({spawn_min_heap_size, -1})
    ).

file_debug_logging_is_disabled_test() ->
    ?assertError(
        debug_log_to_file_disabled,
        eparch_options_ffi:debug_to_erlang({debug_log_to_file, <<"../../secret">>})
    ).

malformed_replies_are_rejected_test() ->
    ?assertError(function_clause, statem_ffi:send_replies([{valid, reply}, malformed])).

invalid_collection_handling_is_rejected_test() ->
    Collection = gen_event:reqids_new(),
    ?assertError(
        function_clause,
        event_manager_ffi:receive_response_collection(Collection, 0, unexpected)
    ).

event_manager_status_is_redacted_by_default_test() ->
    HandlerState =
        {gleam_handler, make_ref(), <<"secret">>, fun(_, State) -> State end, none, none, none,
            none, none},
    Status = #{state => HandlerState, message => <<"secret">>, log => [<<"secret">>]},
    ?assertEqual(
        #{state => redacted, message => redacted, log => []},
        event_manager_ffi:format_status(Status)
    ).

statem_status_is_redacted_by_default_test() ->
    MachineState =
        {gleam_statem, state_secret, data_secret, fun(_, _, _) -> ok end, state_enter_disabled,
            make_ref(), none, none},
    Status = #{
        state => state_secret, data => MachineState, queue => [message_secret], log => [log_secret]
    },
    ?assertEqual(
        #{state => redacted, data => redacted, queue => [], log => []},
        statem_ffi:format_status(Status)
    ).

module_allowlists_are_enforced_test() ->
    Previous = application:get_env(eparch_ffi, allowed_callback_modules),
    try
        ok = application:set_env(eparch_ffi, allowed_callback_modules, [statem_ffi]),
        ?assertEqual(ok, eparch_options_ffi:validate_callback_module(statem_ffi)),
        ?assertError(
            {module_not_allowed, erlang},
            eparch_options_ffi:validate_callback_module(erlang)
        )
    after
        restore_env(allowed_callback_modules, Previous)
    end.

restore_env(Key, undefined) -> application:unset_env(eparch_ffi, Key);
restore_env(Key, {ok, Value}) -> application:set_env(eparch_ffi, Key, Value).
