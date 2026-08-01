-module(codetracer_session).

-behaviour(application).
-behaviour(gen_server).

-export([start/2, stop/1]).
-export([start_session/1, step/1, bind_many/1, stop_session/1]).
-export([web_request_start/1, web_request_stop/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {
    file = undefined,
    session_file = undefined,
    root_pid = undefined,
    root_thread_id = 1,
    pid_threads = #{},
    pid_frames = #{},
    next_frame_id = 1,
    next_runtime_variable_id = 1,
    next_thread_id = 2,
    last_thread_id = undefined,
    exited_pids = #{},
    capture_messages = true,
    source_paths = [],
    manifest_paths = [],
    manifest_index = #{},
    trace_functions = [],
    started = false,
    %% M16: tracer backend selection. process is the default; native dispatches
    %% to codetracer_native_tracer which owns its own writer process and queue.
    tracer_backend = process,
    native_tracer_pid = undefined,
    %% RS-M8: web-request spans.
    %%
    %% next_span_id  -- 1-based, monotonic within the recording; it is the
    %%                  span stream's last-record-wins key.
    %% open_spans    -- SpanId => PidText for spans that have been opened and
    %%                  not yet settled. It is keyed by span id rather than by
    %%                  pid on purpose: a keep-alive connection process serves
    %%                  many requests in sequence, and a proxy-style handler
    %%                  can serve one request inside another, so "the open span
    %%                  of this process" is not a well-defined thing to look up.
    %% web_traced_pids -- PidText => OpenSpanCount for request processes this
    %%                  session turned `call' tracing on for. Cowboy and Bandit
    %%                  spawn their connection processes from the ranch/thousand
    %%                  island supervision tree, NOT from the recorded root
    %%                  process, so `set_on_spawn' never reaches them: without
    %%                  this the request would produce no steps at all and the
    %%                  span would bind to an empty range.
    %%                  It is a COUNT rather than a flag because tracing is a
    %%                  property of the pid while a span is a property of the
    %%                  request: a proxy-style handler serving one request
    %%                  inside another has two open spans on one pid, and
    %%                  turning tracing off when the inner one settles would
    %%                  silence the rest of the outer request. Tracing is
    %%                  turned off only when the last span on the pid settles.
    next_span_id = 1,
    open_spans = #{},
    web_traced_pids = #{}
}).

start(_Type, _Args) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

stop(_State) ->
    ok.

start_session(Options) when is_list(Options) ->
    case gen_server:call(?MODULE, {start_session, Options}, infinity) of
        {ok, _ThreadId} -> ok;
        Other -> Other
    end.

stop_session(Reason) ->
    case whereis(?MODULE) of
        undefined -> ok;
        _Pid -> gen_server:call(?MODULE, {stop_session, Reason}, infinity)
    end.

step(LocationId) when is_integer(LocationId) ->
    case whereis(?MODULE) of
        undefined ->
            ok;
        _Pid ->
            gen_server:call(?MODULE, {step, self(), LocationId}, infinity)
    end.

bind_many(Bindings) when is_list(Bindings) ->
    case whereis(?MODULE) of
        undefined ->
            ok;
        _Pid ->
            gen_server:call(?MODULE, {bind_many, self(), Bindings}, infinity)
    end.

%% RS-M8. Called from the request-handling process itself; the returned span id
%% is held in the caller's own stack frame (the Plug's `call/2' frame and the
%% `before_send' closure it registers), never in a process dictionary or a
%% session-wide "current request" slot. That is what makes a request handled
%% inside another request, or two requests on the same keep-alive connection
%% process, come out as two independent spans.
web_request_start(Metadata) when is_list(Metadata) ->
    case whereis(?MODULE) of
        undefined ->
            {ok, 0};
        _Pid ->
            gen_server:call(
                ?MODULE,
                {web_request_start, self(), Metadata, erlang:system_time(nanosecond)},
                infinity
            )
    end.

web_request_stop(0, _Metadata) ->
    ok;
web_request_stop(SpanId, Metadata) when is_integer(SpanId), is_list(Metadata) ->
    case whereis(?MODULE) of
        undefined ->
            ok;
        _Pid ->
            gen_server:call(
                ?MODULE,
                {web_request_stop, self(), SpanId, Metadata, erlang:system_time(nanosecond)},
                infinity
            )
    end.

init([]) ->
    {ok, #state{}}.

handle_call({start_session, _Options}, _From, State = #state{started = true}) ->
    {reply, {ok, State#state.root_thread_id}, State};
handle_call({start_session, Options}, {RootPid, _Tag}, State) ->
    SessionFile = require_option(session_file, Options),
    SourcePaths = proplists:get_value(source_paths, Options, []),
    ManifestPaths = proplists:get_value(manifest_paths, Options, []),
    TraceFunctions = proplists:get_value(trace_functions, Options, []),
    CaptureMessages = proplists:get_value(capture_messages, Options, true),
    TracerBackend = proplists:get_value(tracer_backend, Options, env_tracer_backend()),
    QueueLimit = proplists:get_value(queue_limit, Options, env_queue_limit()),
    OverflowPolicy = proplists:get_value(
        overflow_policy, Options, env_overflow_policy()),
    ManifestIndex = build_manifest_index(TraceFunctions),
    {ok, LoadedManifests} = load_manifests(ManifestPaths),
    persistent_term:put({codetracer_beam_recorder, manifests}, LoadedManifests),
    persistent_term:put({codetracer_beam_recorder, manifest_index}, ManifestIndex),
    case TracerBackend of
        native ->
            start_native_session(
                State, RootPid, SessionFile, SourcePaths, ManifestPaths,
                LoadedManifests, ManifestIndex, TraceFunctions,
                CaptureMessages, QueueLimit, OverflowPolicy);
        _ ->
            start_process_session(
                State, RootPid, SessionFile, SourcePaths, ManifestPaths,
                LoadedManifests, ManifestIndex, TraceFunctions, CaptureMessages)
    end;
handle_call({stop_session, Reason}, _From, State = #state{started = true,
                                                            tracer_backend = native}) ->
    DeliveryRef = flush_trace_delivery(),
    ok = disable_traces(State),
    ok = clear_message_trace_patterns(State#state.capture_messages),
    ok = clear_trace_patterns(State#state.trace_functions),
    persistent_term:erase({codetracer_beam_recorder, manifests}),
    persistent_term:erase({codetracer_beam_recorder, manifest_index}),
    %% Native backend: the dedicated tracer process owns the file. Tell it
    %% to drain the mailbox and close the file.
    ok = codetracer_native_tracer:stop(Reason, DeliveryRef),
    {reply, ok, #state{}};
handle_call({stop_session, Reason}, _From, State = #state{started = true, file = File}) ->
    DeliveryRef = flush_trace_delivery(),
    StateAfterDrain = drain_trace_messages(File, State),
    ok = disable_traces(StateAfterDrain),
    ok = clear_message_trace_patterns(StateAfterDrain#state.capture_messages),
    ok = clear_trace_patterns(StateAfterDrain#state.trace_functions),
    persistent_term:erase({codetracer_beam_recorder, manifests}),
    persistent_term:erase({codetracer_beam_recorder, manifest_index}),
    ok = write_thread_event(
        File,
        "thread_exit",
        StateAfterDrain#state.root_thread_id,
        StateAfterDrain#state.root_pid,
        StateAfterDrain#state.source_paths
    ),
    ok = write_delivered(File, Reason, DeliveryRef),
    ok = file:sync(File),
    ok = file:close(File),
    {reply, ok, #state{}};
handle_call({stop_session, _Reason}, _From, State) ->
    {reply, ok, State};
handle_call({step, _Pid, _LocationId}, _From, State = #state{started = true,
                                                              tracer_backend = native}) ->
    %% Native backend currently writes step events from inside the native
    %% tracer process. The session gen_server is *not* the writer, so we
    %% intentionally drop step events here. Step recording for the native
    %% backend is tracked as M17 follow-on work; the M16 verification
    %% suite explicitly excludes step coverage from its parity oracle.
    {reply, ok, State};
handle_call({step, Pid, LocationId}, _From, State = #state{started = true, file = File}) ->
    {ThreadId, NewState} = ensure_event_thread(File, Pid, State),
    Line = [
        "{\"event\":\"step\",",
        "\"pid\":", json_string(pid_to_list(Pid)), ",",
        "\"thread_id\":", integer_to_list(ThreadId), ",",
        "\"location_id\":", integer_to_list(LocationId),
        "}\n"
    ],
    ok = file:write(File, Line),
    {reply, ok, NewState};
handle_call({step, _Pid, _LocationId}, _From, State) ->
    {reply, ok, State};
handle_call({bind_many, _Pid, _Bindings}, _From, State = #state{started = true,
                                                                  tracer_backend = native}) ->
    %% Same as step: variable_bind/drop_variables are deferred to M17 on
    %% the native backend. Returning ok keeps instrumented modules happy
    %% while the tracer continues recording call/return/message events.
    {reply, ok, State};
handle_call({bind_many, Pid, Bindings}, _From, State = #state{started = true, file = File}) ->
    {ThreadId, State1} = ensure_event_thread(File, Pid, State),
    State2 = bind_variables(File, Pid, ThreadId, Bindings, State1),
    {reply, ok, State2};
handle_call({bind_many, _Pid, _Bindings}, _From, State) ->
    {reply, ok, State};
%% RS-M8 --- web-request spans.
%%
%% The native backend does not own the sidecar file (codetracer_native_tracer
%% does), so spans are not available there yet. Returning `{ok, 0}' makes the
%% middleware a no-op rather than a crash, matching how `step' and `bind_many'
%% already behave on that backend.
handle_call({web_request_start, _Pid, _Metadata, _WallNs}, _From,
            State = #state{started = true, tracer_backend = native}) ->
    {reply, {ok, 0}, State};
handle_call({web_request_start, Pid, Metadata, WallNs}, _From,
            State0 = #state{started = true, file = File}) ->
    %% Order matters here, and it is the opposite of what it looks like it
    %% should be.
    %%
    %% The recorder samples the writer's exec counter when it replays the
    %% marker, so `start_step' is the index of whatever event comes NEXT. By
    %% writing the marker first and an unconditional `thread_switch' straight
    %% after it, `start_step' is the index of a switch onto the REQUEST's own
    %% thread. That matters because Elixir sources carry no per-line step
    %% instrumentation under `mix run': without this, a request that produced
    %% only call events would open on an index owned by whichever thread
    %% happened to run next, and a solo request would collapse to an empty
    %% range.
    %%
    %% The switch is unconditional rather than via `ensure_event_thread/3'
    %% for the same reason: if the request's thread happened to be current
    %% already, the conditional version writes nothing and the span opens on a
    %% foreign event.
    {ThreadId, State1} = ensure_pid_thread(File, Pid, State0),
    State2 = enable_web_request_tracing(Pid, State1),
    SpanId = State2#state.next_span_id,
    Line = [
        "{\"event\":\"web_request_start\",",
        "\"span_id\":", integer_to_list(SpanId), ",",
        "\"pid\":", json_string(pid_to_list(Pid)), ",",
        "\"thread_id\":", integer_to_list(ThreadId), ",",
        "\"wall_ns\":", integer_to_list(WallNs), ",",
        "\"metadata\":[", join_json(metadata_pairs_json(Metadata)), "]",
        "}\n"
    ],
    ok = file:write(File, Line),
    State3 = force_thread_switch(File, Pid, ThreadId, State2),
    {reply, {ok, SpanId}, State3#state{
        next_span_id = SpanId + 1,
        open_spans = maps:put(SpanId, pid_to_list(Pid), State3#state.open_spans)
    }};
handle_call({web_request_start, _Pid, _Metadata, _WallNs}, _From, State) ->
    {reply, {ok, 0}, State};
handle_call({web_request_stop, _Pid, _SpanId, _Metadata, _WallNs}, _From,
            State = #state{started = true, tracer_backend = native}) ->
    {reply, ok, State};
handle_call({web_request_stop, Pid, SpanId, Metadata, WallNs}, _From,
            State0 = #state{started = true, file = File}) ->
    case maps:is_key(SpanId, State0#state.open_spans) of
        false ->
            %% Already settled (a `before_send' callback and the plug's own
            %% `after' clause both fired), or never opened. Settling twice
            %% would publish a second, later record that last-record-wins
            %% would prefer -- so the first settlement is the one that counts.
            {reply, ok, State0};
        true ->
            %% Mirror of the start marker: the switch goes FIRST, so the
            %% recorder's `end_step = next_step_index() - 1' lands on an event
            %% that belongs to this request's thread rather than on whatever
            %% ran last.
            {ThreadId, State1a} = ensure_pid_thread(File, Pid, State0),
            State1 = force_thread_switch(File, Pid, ThreadId, State1a),
            Line = [
                "{\"event\":\"web_request_stop\",",
                "\"span_id\":", integer_to_list(SpanId), ",",
                "\"pid\":", json_string(pid_to_list(Pid)), ",",
                "\"thread_id\":", integer_to_list(ThreadId), ",",
                "\"wall_ns\":", integer_to_list(WallNs), ",",
                "\"metadata\":[", join_json(metadata_pairs_json(Metadata)), "]",
                "}\n"
            ],
            ok = file:write(File, Line),
            State2 = disable_web_request_tracing(Pid, State1),
            {reply, ok, State2#state{
                open_spans = maps:remove(SpanId, State2#state.open_spans)
            }}
    end;
handle_call({web_request_stop, _Pid, _SpanId, _Metadata, _WallNs}, _From, State) ->
    {reply, ok, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(Message, State = #state{started = true, file = File}) ->
    case write_trace_message(File, Message, State) of
        {ok, NewState} -> {noreply, NewState};
        ignore -> {noreply, State}
    end;
handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, State = #state{started = true}) ->
    catch handle_call({stop_session, terminate}, {self(), make_ref()}, State),
    ok;
terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

require_option(Key, Options) ->
    case proplists:get_value(Key, Options) of
        undefined -> error({missing_required_option, Key});
        Value -> Value
    end.

%% M16: tracer backend dispatch helpers.

env_tracer_backend() ->
    case os:getenv("CODETRACER_BEAM_RECORDER_TRACER_BACKEND") of
        false -> process;
        "process" -> process;
        "native" -> native;
        _ -> process
    end.

env_overflow_policy() ->
    case os:getenv("CODETRACER_BEAM_RECORDER_OVERFLOW_POLICY") of
        false -> block;
        "block" -> block;
        "drop" -> drop;
        _ -> block
    end.

env_queue_limit() ->
    case os:getenv("CODETRACER_BEAM_RECORDER_QUEUE_LIMIT") of
        false -> 65536;
        Value ->
            try list_to_integer(Value) of
                N when N > 0 -> N;
                _ -> 65536
            catch
                _:_ -> 65536
            end
    end.

start_process_session(State, RootPid, SessionFile, SourcePaths, ManifestPaths,
                      LoadedManifests, ManifestIndex, TraceFunctions, CaptureMessages) ->
    ok = filelib:ensure_dir(SessionFile),
    {ok, File} = file:open(SessionFile, [write, {encoding, utf8}]),
    ThreadId = 1,
    RootPidText = pid_to_list(RootPid),
    ok = write_manifest_loaded(File, ManifestPaths, LoadedManifests),
    ok = install_trace_patterns(TraceFunctions),
    ok = install_message_trace_patterns(CaptureMessages),
    erlang:trace(RootPid, true, trace_flags(CaptureMessages)),
    ok = write_thread_event(File, "thread_start", ThreadId, RootPidText, SourcePaths),
    ok = write_thread_event(File, "thread_switch", ThreadId, RootPidText, SourcePaths),
    {reply, {ok, ThreadId}, State#state{
        file = File,
        session_file = SessionFile,
        root_pid = RootPidText,
        root_thread_id = ThreadId,
        pid_threads = #{RootPidText => ThreadId},
        pid_frames = #{},
        next_frame_id = 1,
        next_runtime_variable_id = 1,
        next_thread_id = 2,
        last_thread_id = ThreadId,
        capture_messages = CaptureMessages,
        source_paths = SourcePaths,
        manifest_paths = ManifestPaths,
        manifest_index = ManifestIndex,
        trace_functions = TraceFunctions,
        started = true,
        tracer_backend = process
    }}.

start_native_session(State, RootPid, SessionFile, SourcePaths, ManifestPaths,
                     LoadedManifests, ManifestIndex, TraceFunctions,
                     CaptureMessages, QueueLimit, OverflowPolicy) ->
    %% Start the dedicated native tracer (owns its own file, queue, sequence
    %% counter). The session gen_server still exists to provide the same
    %% start_session/stop_session API and to clear trace patterns at the end.
    ok = filelib:ensure_dir(SessionFile),
    NativeOpts = [
        {session_file, SessionFile},
        {source_paths, SourcePaths},
        {capture_messages, CaptureMessages},
        {manifest_index, ManifestIndex},
        {queue_limit, QueueLimit},
        {overflow_policy, OverflowPolicy}
    ],
    {ok, NativePid} = codetracer_native_tracer:start_link(NativeOpts),
    %% Write manifest_loaded directly via the native tracer's file by sending
    %% a message it understands; for simplicity, we open a short-lived handle
    %% and append the manifest_loaded line at process_session-equivalent time.
    %% Here we rely on the native tracer not having written anything yet, so
    %% we briefly stop using its file for one append.
    ok = append_manifest_loaded_line(SessionFile, ManifestPaths, LoadedManifests),
    %% Tell the tracer about its root pid (it then emits thread_start /
    %% thread_switch with the canonical sequence numbers).
    NativePid ! {native_tracer_register_root, RootPid},
    ok = install_trace_patterns(TraceFunctions),
    ok = install_message_trace_patterns(CaptureMessages),
    %% Install root trace, with the *native tracer process* as tracer.
    ok = codetracer_native_tracer:install_root_trace(RootPid, CaptureMessages),
    ThreadId = 1,
    RootPidText = pid_to_list(RootPid),
    {reply, {ok, ThreadId}, State#state{
        file = undefined,
        session_file = SessionFile,
        root_pid = RootPidText,
        root_thread_id = ThreadId,
        pid_threads = #{RootPidText => ThreadId},
        pid_frames = #{},
        next_frame_id = 1,
        next_runtime_variable_id = 1,
        next_thread_id = 2,
        last_thread_id = ThreadId,
        capture_messages = CaptureMessages,
        source_paths = SourcePaths,
        manifest_paths = ManifestPaths,
        manifest_index = ManifestIndex,
        trace_functions = TraceFunctions,
        started = true,
        tracer_backend = native,
        native_tracer_pid = NativePid
    }}.

%% Append the manifest_loaded JSON line directly to the sidecar file. This is
%% safe because it runs synchronously *before* the native tracer process
%% starts receiving trace messages.
append_manifest_loaded_line(SessionFile, ManifestPaths, LoadedManifests) ->
    {ok, File} = file:open(SessionFile, [append, {encoding, utf8}]),
    ok = write_manifest_loaded(File, ManifestPaths, LoadedManifests),
    ok = file:close(File),
    ok.

trace_function_mfa({Module, Function, Arity, _Kind, _SourcePath, _Line}) ->
    {Module, Function, Arity};
trace_function_mfa({Module, Function, Arity, _Kind, _SourcePath, _Line, _ManifestId, _FunctionKey, _LocationId, _ClauseId, _ResolvedSourcePath, _ResolvedLine, _ResolvedColumn, _ResolutionStrategy, _TraceCopyPath}) ->
    {Module, Function, Arity}.

build_manifest_index(TraceFunctions) ->
    lists:foldl(
        fun(FunctionSpec, Acc) ->
            {Module, Function, Arity} = trace_function_mfa(FunctionSpec),
            maps:put({Module, Function, Arity}, trace_function_metadata(FunctionSpec), Acc)
        end,
        #{},
        TraceFunctions
    ).

trace_function_metadata({_Module, _Function, _Arity, _Kind, SourcePath, Line}) ->
    #{
        source_language => "erlang",
        manifest_id => undefined,
        function_key => undefined,
        location_id => undefined,
        clause_id => undefined,
        source_location => #{
            build_path => SourcePath,
            trace_copy_path => SourcePath,
            line => Line,
            column => undefined,
            resolution => "erl_anno"
        }
    };
trace_function_metadata({_Module, _Function, _Arity, Kind, _SourcePath, _Line, ManifestId, FunctionKey, LocationId, ClauseId, ResolvedSourcePath, ResolvedLine, ResolvedColumn, ResolutionStrategy, TraceCopyPath}) ->
    #{
        source_language => flatten_text(Kind),
        manifest_id => ManifestId,
        function_key => FunctionKey,
        location_id => LocationId,
        clause_id => ClauseId,
        source_location => #{
            build_path => ResolvedSourcePath,
            trace_copy_path => TraceCopyPath,
            line => ResolvedLine,
            column => ResolvedColumn,
            resolution => ResolutionStrategy
        }
    }.

load_manifests(ManifestPaths) ->
    Loaded =
        lists:map(
            fun(Path) ->
                {ok, Binary} = file:read_file(Path),
                #{path => Path, encoding => "json", bytes => byte_size(Binary), json => Binary}
            end,
            ManifestPaths
        ),
    {ok, Loaded}.

write_manifest_loaded(File, ManifestPaths, LoadedManifests) ->
    Line = [
        "{\"event\":\"manifest_loaded\",",
        "\"schema\":\"codetracer.beam.module-manifest.v1\",",
        "\"encoding\":\"json\",",
        "\"persistent_term_key\":\"{codetracer_beam_recorder,manifests}\",",
        "\"manifest_count\":", integer_to_list(length(LoadedManifests)), ",",
        "\"manifest_paths\":[", join_json_strings(ManifestPaths), "]",
        "}\n"
    ],
    ok = file:write(File, Line).

install_trace_patterns(TraceFunctions) ->
    MatchSpec = [{'_', [], [{return_trace}, {exception_trace}]}],
    lists:foreach(
        fun(FunctionSpec) ->
            {Module, Function, Arity} = trace_function_mfa(FunctionSpec),
            _ = code:ensure_loaded(Module),
            _ = erlang:trace_pattern({Module, Function, Arity}, MatchSpec, [local])
        end,
        TraceFunctions
    ),
    ok.

install_message_trace_patterns(true) ->
    _ = erlang:trace_pattern(send, true, []),
    _ = erlang:trace_pattern('receive', [{['_', '$1', '_'], [], [{message, '$1'}]}], []),
    ok;
install_message_trace_patterns(false) ->
    ok.

clear_message_trace_patterns(true) ->
    _ = erlang:trace_pattern(send, false, []),
    _ = erlang:trace_pattern('receive', false, []),
    ok;
clear_message_trace_patterns(false) ->
    ok.

trace_flags(true) ->
    [call, procs, send, 'receive', set_on_spawn, {tracer, self()}];
trace_flags(false) ->
    [call, procs, set_on_spawn, {tracer, self()}].

trace_disable_flags(true) ->
    [call, procs, send, 'receive', set_on_spawn];
trace_disable_flags(false) ->
    [call, procs, set_on_spawn].

%% RS-M8. Flags used for a request-handling process, deliberately NARROWER
%% than trace_flags/1:
%%
%%   * `call' is the point of the exercise -- the trace patterns installed at
%%     start_session only fire for processes that carry this flag, and a
%%     Cowboy/Bandit connection process does not inherit it from the root.
%%   * `procs' + `set_on_spawn' so a handler that spawns a worker keeps that
%%     work inside the recording, and so the process' exit is observed.
%%   * `send'/`receive' are NOT enabled even when capture_messages is on. A
%%     connection process exchanges a message with the socket owner, the
%%     ranch transport and the logger for essentially every byte it moves, and
%%     that traffic is not what a request span is about; including it would
%%     multiply the recording's size without adding anything the panel shows.
web_request_trace_flags() ->
    [call, procs, set_on_spawn, {tracer, self()}].

web_request_trace_disable_flags() ->
    [call, procs, set_on_spawn].

%% Write a `thread_switch' whether or not the thread is already current, and
%% keep `last_thread_id' in step so the ordinary `ensure_event_thread/3' path
%% stays correct afterwards. Only the span markers need this; every other
%% event is happy with the conditional version.
force_thread_switch(File, Pid, ThreadId, State) ->
    ok = write_thread_event(
        File,
        "thread_switch",
        ThreadId,
        pid_to_list(Pid),
        State#state.source_paths
    ),
    State#state{last_thread_id = ThreadId}.

%% Reference-counted per pid: see the `web_traced_pids' note on the state
%% record. The count is of OPEN SPANS on the pid, not of calls to these two
%% functions -- `web_request_stop' only reaches the disable when it actually
%% settles a span, so a doubly-settled request cannot decrement twice.
enable_web_request_tracing(Pid, State = #state{web_traced_pids = Traced}) ->
    PidText = pid_to_list(Pid),
    case maps:get(PidText, Traced, 0) of
        0 ->
            _ = catch erlang:trace(Pid, true, web_request_trace_flags()),
            State#state{web_traced_pids = maps:put(PidText, 1, Traced)};
        Open ->
            State#state{web_traced_pids = maps:put(PidText, Open + 1, Traced)}
    end.

disable_web_request_tracing(Pid, State = #state{web_traced_pids = Traced}) ->
    PidText = pid_to_list(Pid),
    case maps:get(PidText, Traced, 0) of
        0 ->
            State;
        1 ->
            _ = catch erlang:trace(Pid, false, web_request_trace_disable_flags()),
            State#state{web_traced_pids = maps:remove(PidText, Traced)};
        Open ->
            State#state{web_traced_pids = maps:put(PidText, Open - 1, Traced)}
    end.

%% Metadata arrives as a proplist of `{Key, Value}' iodata pairs and is written
%% as a JSON array of two-element arrays, NOT as an object: the span record's
%% metadata is order-preserving all the way to the panel, and a JSON object
%% would invite a decoder to sort it.
metadata_pairs_json(Metadata) ->
    [
        [$[, json_string(Key), $,, json_string(Value), $]]
     || {Key, Value} <- Metadata
    ].

clear_trace_patterns(TraceFunctions) ->
    lists:foreach(
        fun(FunctionSpec) ->
            {Module, Function, Arity} = trace_function_mfa(FunctionSpec),
            _ = erlang:trace_pattern({Module, Function, Arity}, false, [local])
        end,
        TraceFunctions
    ),
    ok.

disable_traces(#state{pid_threads = PidThreads, capture_messages = CaptureMessages}) ->
    maps:fold(
        fun(PidText, _ThreadId, ok) ->
            case list_to_pid_safe(PidText) of
                {ok, Pid} ->
                    _ = catch erlang:trace(Pid, false, trace_disable_flags(CaptureMessages)),
                    ok;
                error ->
                    ok
            end
        end,
        ok,
        PidThreads
    ).

list_to_pid_safe(Text) ->
    try {ok, list_to_pid(Text)}
    catch
        error:badarg -> error
    end.

flush_trace_delivery() ->
    Ref = erlang:trace_delivered(all),
    receive
        {trace_delivered, all, Ref} ->
            Ref
    end.

drain_trace_messages(File, State) ->
    receive
        Message ->
            NewState =
                case write_trace_message(File, Message, State) of
                    {ok, UpdatedState} -> UpdatedState;
                    ignore -> State
                end,
            drain_trace_messages(File, NewState)
    after 0 ->
        State
    end.

write_trace_message(File, {trace, Pid, call, {Module, Function, Args}}, State0) ->
    {ThreadId, State1} = ensure_event_thread(File, Pid, State0),
    Metadata = source_metadata(Module, Function, length(Args), State1),
    {FrameId, State} = push_frame(Pid, Metadata, State1),
    SourceLanguage = maps:get(source_language, Metadata, "erlang"),
    Line = [
        "{\"event\":\"call\",",
        "\"pid\":", json_string(pid_to_list(Pid)), ",",
        "\"thread_id\":", integer_to_list(ThreadId), ",",
        "\"frame_id\":", integer_to_list(FrameId), ",",
        "\"module\":", json_string(atom_to_list(Module)), ",",
        "\"function\":", json_string(atom_to_list(Function)), ",",
        "\"arity\":", integer_to_list(length(Args)), ",",
        "\"source_language\":", json_string(SourceLanguage), ",",
        source_metadata_json(Metadata), ",",
        "\"args\":[", join_json_terms(Args, SourceLanguage), "]",
        "}\n"
    ],
    ok = file:write(File, Line),
    {ok, State};
write_trace_message(File, {trace, Pid, return_from, {Module, Function, Arity}, ReturnValue}, State0) ->
    {ThreadId, State} = ensure_event_thread(File, Pid, State0),
    {FrameInfo, State1} = pop_frame(Pid, State),
    SourceLanguage = frame_source_language(FrameInfo),
    Line = [
        "{\"event\":\"return_from\",",
        "\"pid\":", json_string(pid_to_list(Pid)), ",",
        "\"thread_id\":", integer_to_list(ThreadId), ",",
        "\"frame_id\":", json_nullable_integer(frame_id(FrameInfo)), ",",
        "\"module\":", json_string(atom_to_list(Module)), ",",
        "\"function\":", json_string(atom_to_list(Function)), ",",
        "\"arity\":", integer_to_list(Arity), ",",
        "\"source_language\":", json_string(SourceLanguage), ",",
        "\"return_value\":", json_term(ReturnValue, SourceLanguage),
        "}\n"
    ],
    ok = file:write(File, Line),
    ok = write_drop_variables(File, Pid, ThreadId, FrameInfo),
    {ok, State1};
write_trace_message(File, {trace, Pid, exception_from, {Module, Function, Arity}, {Class, Reason}}, State0) ->
    {ThreadId, State} = ensure_event_thread(File, Pid, State0),
    {FrameInfo, State1} = pop_frame(Pid, State),
    SourceLanguage = frame_source_language(FrameInfo),
    Line = [
        "{\"event\":\"exception_from\",",
        "\"pid\":", json_string(pid_to_list(Pid)), ",",
        "\"thread_id\":", integer_to_list(ThreadId), ",",
        "\"frame_id\":", json_nullable_integer(frame_id(FrameInfo)), ",",
        "\"module\":", json_string(atom_to_list(Module)), ",",
        "\"function\":", json_string(atom_to_list(Function)), ",",
        "\"arity\":", integer_to_list(Arity), ",",
        "\"source_language\":", json_string(SourceLanguage), ",",
        "\"class\":", json_string(atom_to_list(Class)), ",",
        "\"reason\":", json_term(Reason, SourceLanguage), ",",
        "\"reason_repr\":", json_string(io_lib:format("~0tp", [Reason])),
        "}\n"
    ],
    ok = file:write(File, Line),
    ok = write_drop_variables(File, Pid, ThreadId, FrameInfo),
    {ok, State1};
write_trace_message(File, {trace, Pid, spawn, ChildPid, {Module, Function, Args}}, State0) ->
    {_ParentThreadId, State1} = ensure_event_thread(File, Pid, State0),
    {_ChildThreadId, State} = ensure_pid_thread(File, ChildPid, State1),
    Line = [
        "{\"event\":\"process_spawn\",",
        "\"pid\":", json_string(pid_to_list(Pid)), ",",
        "\"child_pid\":", json_string(pid_to_list(ChildPid)), ",",
        "\"module\":", json_string(atom_to_list(Module)), ",",
        "\"function\":", json_string(atom_to_list(Function)), ",",
        "\"arity\":", integer_to_list(length(Args)),
        "}\n"
    ],
    ok = file:write(File, Line),
    {ok, State};
write_trace_message(File, {trace, Pid, spawned, ParentPid, {Module, Function, Args}}, State0) ->
    {ThreadId, State} = ensure_event_thread(File, Pid, State0),
    Line = [
        "{\"event\":\"process_spawned\",",
        "\"pid\":", json_string(pid_to_list(Pid)), ",",
        "\"thread_id\":", integer_to_list(ThreadId), ",",
        "\"parent_pid\":", json_string(pid_to_list(ParentPid)), ",",
        "\"module\":", json_string(atom_to_list(Module)), ",",
        "\"function\":", json_string(atom_to_list(Function)), ",",
        "\"arity\":", integer_to_list(length(Args)),
        "}\n"
    ],
    ok = file:write(File, Line),
    {ok, State};
write_trace_message(File, {trace, Pid, exit, Reason}, State0) ->
    {ThreadId, State1} = ensure_event_thread(File, Pid, State0),
    PidText = pid_to_list(Pid),
    case maps:is_key(PidText, State1#state.exited_pids) of
        true ->
            {ok, State1};
        false ->
            Line = [
                "{\"event\":\"thread_exit\",",
                "\"pid\":", json_string(PidText), ",",
                "\"root_pid\":", json_string(PidText), ",",
                "\"thread_id\":", integer_to_list(ThreadId), ",",
                "\"reason\":", json_term(Reason),
                "}\n"
            ],
            ok = file:write(File, Line),
            {ok, State1#state{exited_pids = maps:put(PidText, true, State1#state.exited_pids)}}
    end;
write_trace_message(File, {trace, Pid, send, Message, Recipient}, State0) ->
    {SenderThreadId, State1} = ensure_event_thread(File, Pid, State0),
    {RecipientPidText, RecipientThreadId, State} = recipient_thread(File, Recipient, State1),
    ok = write_message_event(
        File,
        "message_send",
        "send",
        Pid,
        SenderThreadId,
        RecipientPidText,
        RecipientThreadId,
        Message
    ),
    {ok, State};
write_trace_message(File, {trace, Pid, send_to_non_existing_process, Message, Recipient}, State0) ->
    {SenderThreadId, State} = ensure_event_thread(File, Pid, State0),
    ok = write_message_event(
        File,
        "message_send",
        "send_to_non_existing_process",
        Pid,
        SenderThreadId,
        recipient_text(Recipient),
        undefined,
        Message
    ),
    {ok, State};
write_trace_message(File, {trace, Pid, 'receive', Message, Sender}, State0) ->
    {RecipientThreadId, State1} = ensure_event_thread(File, Pid, State0),
    {SenderPidText, SenderThreadId, State} = sender_thread(File, Sender, State1),
    ok = write_message_event(
        File,
        "message_receive",
        "receive",
        SenderPidText,
        SenderThreadId,
        pid_to_list(Pid),
        RecipientThreadId,
        Message
    ),
    {ok, State};
write_trace_message(File, {trace, Pid, 'receive', Message}, State0) ->
    {RecipientThreadId, State} = ensure_event_thread(File, Pid, State0),
    ok = write_message_event(
        File,
        "message_receive",
        "receive",
        undefined,
        undefined,
        pid_to_list(Pid),
        RecipientThreadId,
        Message
    ),
    {ok, State};
write_trace_message(_File, _Message, _State) ->
    ignore.

source_metadata(Module, Function, Arity, #state{manifest_index = ManifestIndex}) ->
    maps:get({Module, Function, Arity}, ManifestIndex, #{
        source_language => "erlang",
        manifest_id => undefined,
        function_key => undefined,
        location_id => undefined,
        clause_id => undefined,
        source_location => #{
            build_path => "<unknown>",
            trace_copy_path => "generated/<unknown>",
            line => 1,
            column => undefined,
            resolution => "unknown_generated_fallback"
        }
    }).

push_frame(Pid, Metadata, State = #state{pid_frames = PidFrames, next_frame_id = FrameId}) ->
    PidText = pid_to_list(Pid),
    Stack = maps:get(PidText, PidFrames, []),
    FunctionKey = maps:get(function_key, Metadata, undefined),
    SourceLanguage = maps:get(source_language, Metadata, "erlang"),
    Frame = #{
        frame_id => FrameId,
        function_key => FunctionKey,
        source_language => SourceLanguage,
        variables => #{}
    },
    {FrameId, State#state{
        pid_frames = maps:put(PidText, [Frame | Stack], PidFrames),
        next_frame_id = FrameId + 1
    }}.

pop_frame(Pid, State = #state{pid_frames = PidFrames}) ->
    PidText = pid_to_list(Pid),
    case maps:get(PidText, PidFrames, []) of
        [Frame | Rest] ->
            {Frame, State#state{pid_frames = maps:put(PidText, Rest, PidFrames)}};
        [] ->
            {undefined, State}
    end.

frame_id(undefined) ->
    undefined;
frame_id(Frame) ->
    maps:get(frame_id, Frame, undefined).

frame_source_language(undefined) ->
    "erlang";
frame_source_language(Frame) ->
    maps:get(source_language, Frame, "erlang").

bind_variables(_File, _Pid, _ThreadId, [], State) ->
    State;
bind_variables(File, Pid, ThreadId, Bindings, State0 = #state{pid_frames = PidFrames}) ->
    PidText = pid_to_list(Pid),
    case maps:get(PidText, PidFrames, []) of
        [] ->
            State0;
        [Frame0 | Rest] ->
            {Frame, State} =
                lists:foldl(
                    fun(Binding, {CurrentFrame, CurrentState}) ->
                        bind_variable(File, PidText, ThreadId, Binding, CurrentFrame, CurrentState)
                    end,
                    {Frame0, State0},
                    Bindings
                ),
            State#state{pid_frames = maps:put(PidText, [Frame | Rest], State#state.pid_frames)}
    end.

bind_variable(
    File,
    PidText,
    ThreadId,
    {Slot, Name, Value},
    Frame,
    State = #state{next_runtime_variable_id = NextVariableId}
) when is_integer(Slot), is_list(Name) ->
    FrameId = maps:get(frame_id, Frame),
    FunctionKey = maps:get(function_key, Frame, undefined),
    SlotTemplate = slot_template(FunctionKey, Slot),
    Variables0 = maps:get(variables, Frame, #{}),
    case maps:get(SlotTemplate, Variables0, undefined) of
        undefined ->
            RuntimeVariableId = NextVariableId,
            VariableInfo = #{
                runtime_variable_id => RuntimeVariableId,
                slot => Slot,
                slot_template => SlotTemplate,
                name => Name,
                source_language => maps:get(source_language, Frame, "erlang")
            },
            Variables = maps:put(SlotTemplate, VariableInfo, Variables0),
            NewFrame = Frame#{variables => Variables},
            NewState = State#state{next_runtime_variable_id = RuntimeVariableId + 1},
            ok = write_variable_bind(File, PidText, ThreadId, FrameId, VariableInfo, Value),
            {NewFrame, NewState};
        VariableInfo0 ->
            VariableInfo = VariableInfo0#{
                name => Name,
                source_language => maps:get(source_language, Frame, "erlang")
            },
            Variables = maps:put(SlotTemplate, VariableInfo, Variables0),
            NewFrame = Frame#{variables => Variables},
            ok = write_variable_bind(File, PidText, ThreadId, FrameId, VariableInfo, Value),
            {NewFrame, State}
    end;
bind_variable(_File, _PidText, _ThreadId, _Binding, Frame, State) ->
    {Frame, State}.

slot_template(undefined, Slot) ->
    "unknown#" ++ integer_to_list(Slot);
slot_template(FunctionKey, Slot) ->
    flatten_text(FunctionKey) ++ "#" ++ integer_to_list(Slot).

write_variable_bind(File, PidText, ThreadId, FrameId, VariableInfo, Value) ->
    SourceLanguage = maps:get(source_language, VariableInfo, "erlang"),
    Line = [
        "{\"event\":\"variable_bind\",",
        "\"schema\":\"codetracer.beam.variable-binding.v1\",",
        "\"pid\":", json_string(PidText), ",",
        "\"thread_id\":", integer_to_list(ThreadId), ",",
        "\"frame_id\":", integer_to_list(FrameId), ",",
        "\"runtime_variable_id\":", integer_to_list(maps:get(runtime_variable_id, VariableInfo)), ",",
        "\"slot\":", integer_to_list(maps:get(slot, VariableInfo)), ",",
        "\"slot_template\":", json_string(maps:get(slot_template, VariableInfo)), ",",
        "\"name\":", json_string(maps:get(name, VariableInfo)), ",",
        "\"source_language\":", json_string(SourceLanguage), ",",
        "\"value\":", json_term(Value, SourceLanguage),
        "}\n"
    ],
    ok = file:write(File, Line).

write_drop_variables(_File, _Pid, _ThreadId, undefined) ->
    ok;
write_drop_variables(File, Pid, ThreadId, Frame) ->
    Variables = maps:values(maps:get(variables, Frame, #{})),
    case Variables of
        [] ->
            ok;
        _ ->
            Line = [
                "{\"event\":\"drop_variables\",",
                "\"schema\":\"codetracer.beam.variable-binding.v1\",",
                "\"pid\":", json_string(pid_to_list(Pid)), ",",
                "\"thread_id\":", integer_to_list(ThreadId), ",",
                "\"frame_id\":", integer_to_list(maps:get(frame_id, Frame)), ",",
                "\"variables\":[", join_json([dropped_variable_json(Variable) || Variable <- Variables]), "]",
                "}\n"
            ],
            ok = file:write(File, Line)
    end.

dropped_variable_json(VariableInfo) ->
    [
        "{\"runtime_variable_id\":", integer_to_list(maps:get(runtime_variable_id, VariableInfo)), ",",
        "\"slot\":", integer_to_list(maps:get(slot, VariableInfo)), ",",
        "\"slot_template\":", json_string(maps:get(slot_template, VariableInfo)), ",",
        "\"name\":", json_string(maps:get(name, VariableInfo)),
        "}"
    ].

source_metadata_json(Metadata) ->
    SourceLocation = maps:get(source_location, Metadata),
    [
        "\"manifest_id\":", json_nullable_string(maps:get(manifest_id, Metadata)), ",",
        "\"function_key\":", json_nullable_string(maps:get(function_key, Metadata)), ",",
        "\"location_id\":", json_nullable_integer(maps:get(location_id, Metadata)), ",",
        "\"clause_id\":", json_nullable_integer(maps:get(clause_id, Metadata)), ",",
        "\"source_location\":{",
        "\"build_path\":", json_string(maps:get(build_path, SourceLocation)), ",",
        "\"trace_copy_path\":", json_string(maps:get(trace_copy_path, SourceLocation)), ",",
        "\"line\":", integer_to_list(maps:get(line, SourceLocation)), ",",
        "\"column\":", json_nullable_integer(maps:get(column, SourceLocation)), ",",
        "\"resolution\":", json_string(maps:get(resolution, SourceLocation)),
        "}"
    ].

write_thread_event(File, Event, ThreadId, RootPid, SourcePaths) ->
    Line = [
        "{\"event\":\"", Event, "\",",
        "\"thread_id\":", integer_to_list(ThreadId), ",",
        "\"pid\":", json_string(RootPid), ",",
        "\"root_pid\":", json_string(RootPid), ",",
        "\"source_paths\":[", join_json_strings(SourcePaths), "]",
        "}\n"
    ],
    ok = file:write(File, Line).

write_delivered(File, Reason, DeliveryRef) ->
    Line = [
        "{\"event\":\"trace_delivered\",",
        "\"delivery_target\":\"all\",",
        "\"delivery_ref\":", json_string(io_lib:format("~p", [DeliveryRef])), ",",
        "\"reason\":", json_string(io_lib:format("~p", [Reason])),
        "}\n"
    ],
    ok = file:write(File, Line).

ensure_event_thread(File, Pid, State0) ->
    {ThreadId, State1} = ensure_pid_thread(File, Pid, State0),
    case State1#state.last_thread_id of
        ThreadId ->
            {ThreadId, State1};
        _ ->
            ok = write_thread_event(
                File,
                "thread_switch",
                ThreadId,
                pid_to_list(Pid),
                State1#state.source_paths
            ),
            {ThreadId, State1#state{last_thread_id = ThreadId}}
    end.

ensure_pid_thread(File, Pid, State = #state{pid_threads = PidThreads}) when is_pid(Pid) ->
    PidText = pid_to_list(Pid),
    case maps:get(PidText, PidThreads, undefined) of
        undefined ->
            ThreadId = State#state.next_thread_id,
            ok = write_thread_event(File, "thread_start", ThreadId, PidText, State#state.source_paths),
            {ThreadId, State#state{
                pid_threads = maps:put(PidText, ThreadId, PidThreads),
                next_thread_id = ThreadId + 1
            }};
        ThreadId ->
            {ThreadId, State}
    end.

recipient_thread(File, Recipient, State) when is_pid(Recipient) ->
    {ThreadId, NewState} = ensure_pid_thread(File, Recipient, State),
    {pid_to_list(Recipient), ThreadId, NewState};
recipient_thread(_File, Recipient, State) ->
    {recipient_text(Recipient), undefined, State}.

sender_thread(File, Sender, State) when is_pid(Sender) ->
    {ThreadId, NewState} = ensure_pid_thread(File, Sender, State),
    {pid_to_list(Sender), ThreadId, NewState};
sender_thread(_File, Sender, State) ->
    {sender_text(Sender), undefined, State}.

recipient_text(undefined) ->
    undefined;
recipient_text(Recipient) when is_pid(Recipient) ->
    pid_to_list(Recipient);
recipient_text(Recipient) ->
    io_lib:format("~0tp", [Recipient]).

sender_text(undefined) ->
    undefined;
sender_text(Sender) when is_pid(Sender) ->
    pid_to_list(Sender);
sender_text(Sender) ->
    io_lib:format("~0tp", [Sender]).

write_message_event(
    File,
    Event,
    TraceTag,
    SenderPid,
    SenderThreadId,
    RecipientPid,
    RecipientThreadId,
    Message
) ->
    {MessageRepr, MessageTruncated} = bounded_term(Message, 512),
    Line = [
        "{\"event\":\"", Event, "\",",
        "\"schema\":\"codetracer.beam.message.v1\",",
        "\"direction\":", json_string(message_direction(Event)), ",",
        "\"trace_tag\":", json_string(TraceTag), ",",
        "\"tag\":", json_string(message_tag(Message)), ",",
        "\"sender_pid\":", json_nullable_string(pid_text(SenderPid)), ",",
        "\"sender_thread_id\":", json_nullable_integer(SenderThreadId), ",",
        "\"recipient_pid\":", json_nullable_string(pid_text(RecipientPid)), ",",
        "\"recipient_thread_id\":", json_nullable_integer(RecipientThreadId), ",",
        "\"message_format\":\"erlang_external_text\",",
        "\"message_repr\":", json_string(MessageRepr), ",",
        "\"message_truncated\":", json_boolean(MessageTruncated),
        "}\n"
    ],
    ok = file:write(File, Line).

message_direction("message_send") ->
    "send";
message_direction("message_receive") ->
    "receive".

pid_text(undefined) ->
    undefined;
pid_text(Pid) when is_pid(Pid) ->
    pid_to_list(Pid);
pid_text(Text) ->
    Text.

message_tag(Message) when is_tuple(Message), tuple_size(Message) > 0 ->
    tag_text(element(1, Message));
message_tag(Message) ->
    tag_text(Message).

tag_text(Value) when is_atom(Value) ->
    atom_to_list(Value);
tag_text(Value) when is_integer(Value) ->
    "integer";
tag_text(Value) when is_binary(Value) ->
    "binary";
tag_text(Value) when is_list(Value) ->
    "list";
tag_text(Value) when is_tuple(Value) ->
    "tuple";
tag_text(Value) when is_pid(Value) ->
    "pid";
tag_text(_Value) ->
    "term".

bounded_term(Value, Limit) ->
    Text = lists:flatten(io_lib:format("~0tp", [Value])),
    case length(Text) > Limit of
        true ->
            {string:substr(Text, 1, Limit), true};
        false ->
            {Text, false}
    end.

join_json_strings([]) ->
    "";
join_json_strings([Value]) ->
    json_string(Value);
join_json_strings([Value | Rest]) ->
    [json_string(Value), ",", join_json_strings(Rest)].

join_json_terms([]) ->
    "";
join_json_terms([Value]) ->
    json_term(Value);
join_json_terms([Value | Rest]) ->
    [json_term(Value), ",", join_json_terms(Rest)].

join_json_terms([], _SourceLanguage) ->
    "";
join_json_terms([Value], SourceLanguage) ->
    json_term(Value, SourceLanguage);
join_json_terms([Value | Rest], SourceLanguage) ->
    [json_term(Value, SourceLanguage), ",", join_json_terms(Rest, SourceLanguage)].

join_json([]) ->
    "";
join_json([Value]) ->
    Value;
join_json([Value | Rest]) ->
    [Value, ",", join_json(Rest)].

json_term(Value) ->
    json_term(Value, "erlang").

json_term(Value, SourceLanguage) ->
    codetracer_value_encoder:json(Value, SourceLanguage).

json_nullable_string(undefined) ->
    "null";
json_nullable_string(Value) ->
    json_string(Value).

json_nullable_integer(undefined) ->
    "null";
json_nullable_integer(nil) ->
    "null";
json_nullable_integer(Value) ->
    integer_to_list(Value).

json_boolean(true) ->
    "true";
json_boolean(false) ->
    "false".

json_string(Value) ->
    [$", escape_json(flatten_text(Value)), $"].

flatten_text(Value) when is_binary(Value) ->
    binary_to_list(Value);
flatten_text(Value) ->
    lists:flatten(Value).

escape_json([]) ->
    [];
escape_json([$" | Rest]) ->
    [$\\, $" | escape_json(Rest)];
escape_json([$\\ | Rest]) ->
    [$\\, $\\ | escape_json(Rest)];
escape_json([$\n | Rest]) ->
    [$\\, $n | escape_json(Rest)];
escape_json([$\r | Rest]) ->
    [$\\, $r | escape_json(Rest)];
escape_json([$\t | Rest]) ->
    [$\\, $t | escape_json(Rest)];
escape_json([Char | Rest]) ->
    [Char | escape_json(Rest)].
