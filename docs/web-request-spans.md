# Web-request spans (Plug and Phoenix)

The recorder can partition a recording into one **span** per HTTP request, so
CodeTracer's Request Panel shows a row per request and double-clicking a row
seeks into that request's own interval of the recording.

Spans live in the `.ct` container itself (`spans.dat`, guarded by `meta.dat`
bit 13). There is no sidecar file to find, tail or keep in sync — see
`codetracer-specs/Trace-Files/CTFS-Request-Span-Streams.md`.

## Installing the middleware

Add `CodetracerBeamRecorder.Plug` to the pipeline. It is a no-op when no
recorder is attached — `:codetracer_erlang_runtime` is not loaded, and the plug
returns the conn untouched — so it is safe to leave in a production pipeline.

### Plug

```elixir
defmodule MyApp.Endpoint do
  use Plug.Builder
  use Plug.ErrorHandler

  plug CodetracerBeamRecorder.Plug, framework: "plug"
  plug MyApp.Router
end
```

### Phoenix

Install it **outside** the endpoint:

```elixir
defmodule MyApp.TracedEndpoint do
  use Plug.Builder

  plug CodetracerBeamRecorder.Plug, framework: "phoenix", router: MyAppWeb.Router
  plug MyAppWeb.Endpoint
end

# in the supervision tree
{Plug.Cowboy, scheme: :http, plug: MyApp.TracedEndpoint, options: [port: 4000]}
```

`use Phoenix.Endpoint` wraps the endpoint's pipeline in `Plug.ErrorHandler`,
which rescues with the conn that was in flight when the failing plug raised. A
plug installed inside the endpoint has not registered its `before_send` callback
on that conn, so an unmatched route — which Phoenix answers by raising
`Phoenix.Router.NoRouteError` and rendering it — would leave the span open.
Installed outside, the callback is already there and the 404 settles like any
other response.

Passing `router:` explicitly matters for the same reason: a request that never
reached the router never gets `conn.private[:phoenix_router]` set.

## Options

| Option       | Meaning                                                                 |
| ------------ | ----------------------------------------------------------------------- |
| `:framework` | the `framework` metadata value; defaults to `"plug"`                    |
| `:router`    | a `Phoenix.Router` module; `http.route` is resolved through it          |
| `:route_fun` | a 1-arity function over the conn returning a route pattern              |

Without either, the middleware falls back to `conn.private[:phoenix_router]`
and then to `Plug.Router`'s own `conn.private[:plug_route]`.

## What a span carries

| Key                  | Example                 |
| -------------------- | ----------------------- |
| `http.method`        | `GET`                   |
| `http.url`           | `/api/users/2`          |
| `framework`          | `phoenix`               |
| `http.status_code`   | `200`                   |
| `http.duration_ms`   | `12`                    |
| `http.response_size` | `18`                    |
| `http.route`         | `/api/users/:user_id`   |
| `beam.pid`           | `<0.283.0>`             |
| `beam.thread_id`     | `29`                    |

`http.route` is the **routed pattern**, not the path the client typed, so the
panel can group `/api/users/1` and `/api/users/2` as one route. A request that
matched no route records an empty `http.route`, which is how a 404 by routing is
distinguishable from a 404 a controller chose to return.

`beam.pid` and `beam.thread_id` are written by the recorder, not by the
middleware: they are what the session actually bound the span to.

## The coordinate: a BEAM process is a thread

A span's coordinate is *(process_ord, thread_id, step range)*. The recorder
records **one OS process** — the `beam.smp` it launched — so every web-request
span carries `process_ord = 0`. Each *BEAM* process is mapped onto a container
**thread** (`codetracer_session:ensure_pid_thread/3` mints a thread id per pid),
so requests served concurrently by Cowboy's per-connection processes are
distinguished by `thread_id`.

Cowboy and Bandit spawn their connection processes from the ranch supervision
tree, not from the recorded root process, so `set_on_spawn` does not reach them.
The session therefore turns `call` tracing **on** for a request process when its
span opens and off again when it settles: the request's own work is recorded,
and the connection process' idle life between requests is not.

## Structural bits

The three bits from `Trace-Spans.md` § 2.4 are measured from the recording, not
declared:

- `shares_timeline` — always true. One writer, one exec stream, comparable
  step ids.
- `concurrent_with_siblings` — true when the span's step range overlaps another
  web-request span's. Normally true under load, false for a request served
  while the server was idle.
- `contiguous_on_one_thread` — true only when no `thread_switch` inside the
  span's range moves to a different thread. A BEAM process handles its request
  start to finish, but the *container's* exec stream is shared, so an
  overlapping request has its neighbours' events interleaved into its range and
  is not contiguous.

## Step ranges and Elixir

The recorder applies step instrumentation to `.erl` sources. An Elixir
application recorded through `mix run` reaches the container as call/return
records in `calls.dat`, so a request's step range is made of the thread events
that bracket it. That is a real, distinct, ordered coordinate — the panel seeks
to it, and every request gets its own — but it does not resolve to a line of
`router.ex`. Per-line steps for Elixir sources are a separate piece of work.

## Reading them back

```sh
codetracer-beam-recorder read-spans --bundle ct-traces           # settled rows
codetracer-beam-recorder read-spans --bundle ct-traces --all     # open + settled
ct print -f http ct-traces
```

Both go through the canonical Nim span decoder, so what a test asserts is what
the GUI reads.

## Demos

```sh
just prepare-web-fixtures                # fetch plug_cowboy / phoenix from Hex
just demo-request-panel-elixir plug      # test-programs/elixir/plug_web
just demo-request-panel-elixir phoenix   # test-programs/elixir/phoenix_web
```
