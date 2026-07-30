defmodule CodetracerBeamRecorder.Plug do
  @moduledoc """
  Plug middleware that records one CodeTracer **web-request span** per HTTP
  request, inline in the recording's own `.ct` container.

  This is the RS-M8 middleware described in
  `codetracer-specs/Planned-Features/Request-Panel-Live-Sessions.milestones.org`.
  There is no sidecar file: the span goes to
  `:codetracer_erlang_runtime.web_request_start/1` and
  `:codetracer_erlang_runtime.web_request_stop/2`, and the recorder binds it to
  a `(process_ord, thread_id, step range)` coordinate inside the container it
  is already writing.

  ## Where to put it

      defmodule MyApp.Router do
        use Plug.Router
        plug CodetracerBeamRecorder.Plug
        plug :match
        plug :dispatch
        # ...
      end

  For Phoenix, install it **outside** the endpoint, so it is still in the
  pipeline when `Phoenix.Endpoint`'s error handler renders a 404 or a 500:

      defmodule MyApp.TracedEndpoint do
        use Plug.Builder
        plug CodetracerBeamRecorder.Plug, framework: "phoenix", router: MyAppWeb.Router
        plug MyAppWeb.Endpoint
      end

      # in the supervision tree
      {Plug.Cowboy, scheme: :http, plug: MyApp.TracedEndpoint, options: [port: 4000]}

  `use Phoenix.Endpoint` wraps the whole endpoint in `Plug.ErrorHandler`, and
  that handler rescues with the conn it *received*.  A plug installed inside
  the endpoint has not registered its `before_send` callback on that conn yet,
  so an unmatched route would settle no span.  Installed outside, the callback
  is already on the conn the error renderer sends, and the 404 is recorded like
  any other response.

  ## Options

    * `:framework` — the `framework` metadata value; defaults to `"plug"`.
    * `:router` — a `Phoenix.Router` module.  When given, `http.route` is the
      *routed pattern* (`"/api/users/:user_id"`), resolved through
      `Phoenix.Router.route_info/4`, not the request path.  For a request that
      matched no route it is the empty string, which is how the panel can tell
      a 404-by-routing from a 404 a handler chose to return.
    * `:route_fun` — a 1-arity function over the `Plug.Conn` returning the
      route pattern, for frameworks whose routing this module does not know.

  ## Not recording

  Every entry point is guarded: with no recorder attached,
  `:codetracer_erlang_runtime` is not even loaded, `recording?/0` is false and
  `call/2` returns the conn untouched.  The module is therefore safe to leave
  in a production pipeline.

  ## Per-request state

  The span id lives in the `call/2` stack frame and in the `before_send`
  closure that frame creates — never in the process dictionary and never in a
  "current request" slot on the session.  Two requests served by one keep-alive
  connection process, and a request handled inside another request, are
  therefore two independent spans.
  """

  @behaviour Plug

  @runtime :codetracer_erlang_runtime

  @impl true
  def init(opts) when is_list(opts), do: opts
  def init(opts), do: [framework: to_string(opts)]

  @impl true
  def call(conn, opts) do
    if recording?() do
      framework = opts |> Keyword.get(:framework, "plug") |> to_string()
      # Taken BEFORE the span is opened so `http.duration_ms` covers the same
      # interval as the span's own `start_wall_ns` / `end_wall_ns` pair.  Under
      # a recorder the call that opens the span is not free, and a duration
      # that silently excluded it would disagree with the span's wall clock.
      started_at = System.monotonic_time(:microsecond)

      {:ok, span_id} =
        @runtime.web_request_start([
          {"http.method", conn.method},
          {"http.url", request_url(conn)},
          {"framework", framework}
        ])

      if span_id == 0 do
        conn
      else
        Plug.Conn.register_before_send(conn, fn sent_conn ->
          :ok = @runtime.web_request_stop(span_id, stop_metadata(sent_conn, opts, started_at))
          sent_conn
        end)
      end
    else
      conn
    end
  end

  @doc """
  Whether a CodeTracer recording session is attached to this VM.

  `Code.ensure_loaded?/1` is the load attempt itself, so this is a code-server
  lookup after the first call rather than a repeated load.
  """
  def recording? do
    Code.ensure_loaded?(@runtime) and function_exported?(@runtime, :web_request_start, 1)
  end

  defp stop_metadata(conn, opts, started_at) do
    duration_ms =
      div(System.monotonic_time(:microsecond) - started_at + 500, 1000)

    [
      {"http.status_code", to_string(conn.status || 0)},
      {"http.duration_ms", to_string(duration_ms)},
      {"http.response_size", to_string(response_size(conn))},
      {"http.route", route(conn, opts)}
    ]
  end

  # `resp_body` is an iodata chunk for a `send_resp/3` response and `nil` for a
  # chunked or file response, where the size is not knowable from the conn.
  defp response_size(%{resp_body: nil}), do: 0

  defp response_size(%{resp_body: body}) do
    IO.iodata_length(body)
  rescue
    ArgumentError -> 0
  end

  defp request_url(conn) do
    case conn.query_string do
      "" -> conn.request_path
      nil -> conn.request_path
      query -> conn.request_path <> "?" <> query
    end
  end

  defp route(conn, opts) do
    cond do
      route_fun = Keyword.get(opts, :route_fun) ->
        to_string(route_fun.(conn) || "")

      router = Keyword.get(opts, :router) ->
        phoenix_route(conn, router)

      router = conn.private[:phoenix_router] ->
        phoenix_route(conn, router)

      # `Plug.Router` records the pattern it matched as `{path, fun}` — the
      # same "routed pattern, not raw path" the Phoenix branch resolves, and
      # the reason a `/api/users/1` and a `/api/users/2` row group together in
      # the panel.
      match?({path, _fun} when is_binary(path), conn.private[:plug_route]) ->
        {path, _fun} = conn.private[:plug_route]
        path

      true ->
        ""
    end
  end

  # `Phoenix.Router.route_info/4` is the public routing oracle; it returns the
  # pattern the request matched (`"/api/users/:user_id"`), or `:error` when
  # nothing matched — which is exactly the 404 case the milestone asks to be
  # distinguishable from a routed response.
  #
  # It is reached through a runtime-built module name rather than a literal
  # `Phoenix.Router.route_info(...)` call, so this file compiles in a project
  # that has Plug but not Phoenix without an "undefined module" warning (and
  # therefore without a `--warnings-as-errors` failure).
  defp phoenix_route(conn, router) do
    phoenix_router = Module.concat([:Phoenix, :Router])

    case apply(phoenix_router, :route_info, [router, conn.method, conn.request_path, conn.host]) do
      %{route: route} when is_binary(route) -> route
      _ -> ""
    end
  rescue
    _ -> ""
  end
end
