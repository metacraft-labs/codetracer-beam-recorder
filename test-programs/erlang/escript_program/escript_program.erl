%% Fixture for the `escript <program>.erl` launch target.
%%
%% `ct record foo.erl` makes the CodeTracer desktop core dispatch
%%   codetracer-beam-recorder record --out-dir D --source-dir S -- escript foo.erl
%% (src/ct/trace/recorder_dispatch.nim, LangErlang).  `escript` runs a bare
%% `.erl` source by compiling it and calling `main/1`, so this file has to
%% define `main/1` and nothing else may run at load time.
%%
%% KEEP THIS PROGRAM BORING: fixed inputs, deterministic output, no clock, no
%% randomness, no OTP application.  The recorded trace is asserted against
%% exact expectations in tests/integration/launch_targets_test.exs.
-module(escript_program).

-export([main/1, accumulate/1, accumulate/2, describe/0]).

%% Sum a fixed list with explicit recursion so the trace has real steps.
accumulate(Values) ->
    accumulate(Values, 0).

accumulate([], Total) ->
    Total;
accumulate([Value | Rest], Total) ->
    accumulate(Rest, Total + Value).

%% Report the escript-target marker, so the recorded call has a return value
%% the test can assert on.
describe() ->
    "escript-launch-target".

main(_Args) ->
    Total = accumulate([1, 2, 3, 4, 5]),
    io:format("escript-program: total=~p~n", [Total]),
    io:format("escript-program: describe=~s~n", [describe()]),
    Total.
