%%% Deep-nesting fixture: 30000 recursive calls, none of which returns until
%%% the innermost one does. Under call tracing with `return_trace' the BEAM
%%% keeps every frame, so the recording holds 30000 nested calls that all
%%% complete at once when the recursion unwinds.
-module(deep_calls).
-export([main/0, depth/1]).

-define(N, 30000).

main() ->
    ?N = depth(?N),
    io:format("deep-calls-ok ~p~n", [?N]),
    ok.

depth(0) ->
    0;
depth(N) when N > 0 ->
    1 + depth(N - 1).
