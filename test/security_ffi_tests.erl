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

%% The fixture saves both allowlists before each test and restores them from
%% the EUnit runner afterwards, even if the test process crashes or is killed.
allowlists_test_() ->
    {foreach, fun save_allowlists/0, fun restore_allowlists/1, [
        fun callback_allowlist_is_enforced/0,
        fun registry_allowlist_guards_via_names/0
    ]}.

callback_allowlist_is_enforced() ->
    ok = application:set_env(eparch_ffi, allowed_callback_modules, [statem_ffi]),
    ?assertEqual(ok, eparch_options_ffi:validate_callback_module(statem_ffi)),
    ?assertError({module_not_allowed, erlang}, eparch_options_ffi:validate_callback_module(erlang)).

registry_allowlist_guards_via_names() ->
    ok = application:set_env(eparch_ffi, allowed_registry_modules, [global]),
    ?assertEqual({via, global, name}, eparch_options_ffi:validate_server_name({via, global, name})),
    ?assertError(
        {module_not_allowed, erlang}, eparch_options_ffi:validate_server_name({via, erlang, name})
    ).

save_allowlists() ->
    [
        {Key, application:get_env(eparch_ffi, Key)}
     || Key <- [allowed_callback_modules, allowed_registry_modules]
    ].

restore_allowlists(Saved) ->
    lists:foreach(fun restore_env/1, Saved).

restore_env({Key, undefined}) -> application:unset_env(eparch_ffi, Key);
restore_env({Key, {ok, Value}}) -> application:set_env(eparch_ffi, Key, Value).
