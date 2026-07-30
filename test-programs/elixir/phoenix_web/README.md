# `phoenix_web` — the RS-M8 Phoenix demo

A real `Phoenix.Endpoint`, `Phoenix.Router` and controllers behind a real
Cowboy listener, recorded end to end by
`tests/integration/phoenix_requests_test.exs` and opened in the GUI by
`just demo-request-panel-elixir phoenix`.

Phoenix is here for one thing the plain Plug demo cannot show: the router knows
the **pattern** a request matched. `/api/users/1` and `/api/users/2` both record
`http.route == "/api/users/:user_id"`, which is what lets the Request Panel
group rows by route instead of by URL.

## Layout

| File                                | What it is                                                       |
| ----------------------------------- | ---------------------------------------------------------------- |
| `lib/phoenix_web.ex`                | the driver: starts the endpoint and Cowboy, issues the requests   |
| `lib/phoenix_web/traced_endpoint.ex`| `CodetracerBeamRecorder.Plug` wrapped **around** the endpoint      |
| `lib/phoenix_web/endpoint.ex`       | a real `Phoenix.Endpoint`, run with `server: false`               |
| `lib/phoenix_web/router.ex`         | the routes, including a two-parameter one                         |
| `lib/phoenix_web/*_controller.ex`   | the handlers, including one that raises                           |
| `lib/phoenix_web/error_*.ex`        | Phoenix's `render_errors` views                                   |
| `config/config.exs`                 | endpoint config; `server: false` because Cowboy is started by hand |

## Why the middleware is outside the endpoint

`use Phoenix.Endpoint` wraps the endpoint's whole pipeline in
`Plug.ErrorHandler`, and `Phoenix.Endpoint`'s `RenderErrors` turns the
`Phoenix.Router.NoRouteError` an unmatched path raises into the 404 the client
sees. That renderer sends the response on the conn that was in flight when the
router raised, so a plug installed *inside* the endpoint would have registered
its `before_send` callback on a conn the error path never sends — and every 404
would leave a span open. `PhoenixWeb.TracedEndpoint` therefore puts the plug in
front of the endpoint, and `phoenix_requests_test.exs` asserts that no span is
left open.

The router is passed to the plug explicitly rather than being read from
`conn.private[:phoenix_router]`, because a request that never reached the router
never gets that private key set — which is exactly the 404 the test needs to
distinguish from a routed response. An unrouted request records an empty
`http.route`; a 404 a controller chose to return records the route it matched.
