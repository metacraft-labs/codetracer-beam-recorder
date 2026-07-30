-module(codetracer_erlang_runtime).

-export([start_session/1, step/1, bind_many/1, stop_session/1]).
-export([web_request_start/1, web_request_stop/2]).

start_session(Options) when is_list(Options) ->
    case application:ensure_all_started(codetracer_erlang_runtime) of
        {ok, _Started} ->
            codetracer_session:start_session(Options);
        {error, {already_started, codetracer_erlang_runtime}} ->
            codetracer_session:start_session(Options);
        {error, Reason} ->
            {error, Reason}
    end.

stop_session(Reason) ->
    codetracer_session:stop_session(Reason).

step(LocationId) when is_integer(LocationId) ->
    codetracer_session:step(LocationId).

bind_many(Bindings) when is_list(Bindings) ->
    codetracer_session:bind_many(Bindings).

%% RS-M8: web-request spans.
%%
%% Both functions are called from the process that is handling the request
%% (a Cowboy/Bandit connection process under Plug or Phoenix), never from a
%% supervisor or from the recorder. That is deliberate: the span's thread
%% coordinate is the calling process' own thread id, so the recorder can bind
%% the span to the steps that process produced.
%%
%% `Metadata' is a proplist of `{Key, Value}' pairs, both iodata. Order is
%% preserved end to end -- consumers render the well-known `http.*' keys in
%% emission order.
%%
%% Returns `{ok, SpanId}'. When no session is running (the app is executing
%% outside the recorder) `{ok, 0}' is returned and nothing is written, so the
%% middleware is a no-op in production.
web_request_start(Metadata) when is_list(Metadata) ->
    codetracer_session:web_request_start(Metadata).

web_request_stop(SpanId, Metadata) when is_integer(SpanId), is_list(Metadata) ->
    codetracer_session:web_request_stop(SpanId, Metadata).
