# `plug_web` — the RS-M8 Plug/Cowboy demo

A real `Plug.Router` behind a real Cowboy listener, recorded end to end by
`tests/integration/plug_requests_test.exs` and opened in the GUI by
`just demo-request-panel-elixir plug`.

This is `plug_smoke` promoted to the genuine article. `plug_smoke` stays where
it is: it hand-rolls HTTP over `:gen_tcp` so it needs nothing from Hex, which
makes it the one request-shaped fixture that runs with no network at all. This
one takes `plug_cowboy` from Hex (`just prepare-web-fixtures`) because the
middleware under test is a *Plug*, and testing it against a re-implementation
of Plug would test the re-implementation.

## Layout

| File                     | What it is                                                              |
| ------------------------ | ----------------------------------------------------------------------- |
| `lib/plug_web.ex`        | the driver: starts Cowboy on an ephemeral port, issues the requests, stops |
| `lib/plug_web/endpoint.ex` | `CodetracerBeamRecorder.Plug` in front of the router, plus `Plug.ErrorHandler` |
| `lib/plug_web/router.ex` | the routes — every status bucket the Request Panel colours              |
| `lib/plug_web/barrier.ex` | the rendezvous that makes the concurrent phase provably concurrent      |

## The two schedules

`PlugWeb.main/0` runs a cohort of `CT_PLUG_WEB_COHORT` (default 4) requests
against `/concurrent/:slot`, each of which blocks in `PlugWeb.Barrier` until
the whole cohort has arrived — so all of them are inside a handler at the same
instant and their spans' step ranges must interleave. It then issues eight more
requests one at a time.

`CT_PLUG_WEB_SEQUENTIAL=1` sizes the barrier to one and issues everything
serially. That second schedule is the falsifiability control for
`plug_requests_test.exs`: the same program, the same routes and the same
recorder must stop reporting overlapping spans.

`CT_PLUG_WEB_SLOW_MS` (default 400) is how long `/slow` sleeps inside its
handler.

## Why the middleware is outside the router

`Plug.ErrorHandler` rescues with the conn that was in flight when the handler
raised. A plug installed *inside* the router would have registered its
`before_send` callback on a conn the error path never sends, so `/boom` would
leave an open span. Installed in `PlugWeb.Endpoint`, ahead of the router, the
callback is on the conn the error handler sends and the 500 is recorded like
any other response. The Phoenix demo places it outside its endpoint for exactly
the same reason.
