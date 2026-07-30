defmodule PhoenixWeb.Endpoint do
  @moduledoc """
  A real `Phoenix.Endpoint`.

  It runs with `server: false`; `PhoenixWeb.main/0` starts Cowboy itself
  around `PhoenixWeb.TracedEndpoint`, which wraps this endpoint in the
  CodeTracer plug. See that module for why the plug cannot live inside here.
  """

  use Phoenix.Endpoint, otp_app: :phoenix_web

  plug(Plug.Parsers,
    parsers: [:urlencoded, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(PhoenixWeb.Router)
end
