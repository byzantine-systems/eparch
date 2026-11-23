-module(eparch_delivery_tests).
-include_lib("eunit/include/eunit.hrl").

abandoned_reply_never_reaches_caller_test() ->
    Parent = self(),
    Server = spawn(fun() ->
        receive
            {work, Ref} ->
                receive
                    release -> ok
                end,
                eparch_delivery_ffi:respond(Ref, done),
                Parent ! processed
        end
    end),
    ?assertEqual(
        {error, wait_timeout},
        eparch_delivery_ffi:request(Server, 0, fun(Ref, _) ->
            Server ! {work, Ref},
            nil
        end)
    ),
    Server ! release,
    receive
        processed -> ok
    after 1000 -> error(no_receipt)
    end,
    receive
        {_, done} -> error(late_reply)
    after 0 -> ok
    end.
