import Config

# The endpoint is started with `server: false` and Cowboy is started by hand in
# `PhoenixWeb.main/0` around `PhoenixWeb.TracedEndpoint`, so that
# `CodetracerBeamRecorder.Plug` sits OUTSIDE `Phoenix.Endpoint`. That placement
# is what lets a 404 -- which Phoenix renders from its own error handler after
# the router raises `Phoenix.Router.NoRouteError` -- still run the plug's
# `before_send` callback and settle its span.
config :phoenix_web, PhoenixWeb.Endpoint,
  server: false,
  secret_key_base: String.duplicate("codetracer-beam-recorder-rs-m8", 3),
  render_errors: [formats: [json: PhoenixWeb.ErrorJSON, html: PhoenixWeb.ErrorHTML], layout: false]

config :logger, level: :warning
