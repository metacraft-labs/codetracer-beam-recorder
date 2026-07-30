defmodule PhoenixWeb.TracedEndpoint do
  @moduledoc """
  The plug Cowboy actually serves: `CodetracerBeamRecorder.Plug` in front of
  the Phoenix endpoint.

  `use Phoenix.Endpoint` wraps the endpoint's whole pipeline in
  `Plug.ErrorHandler`, and `Phoenix.Endpoint`'s `RenderErrors` turns a
  `Phoenix.Router.NoRouteError` into the 404 the client sees. That renderer
  sends the response on the conn that was in flight when the router raised --
  so a plug installed *inside* the endpoint would have registered its
  `before_send` callback on a conn the error path never sends, and every 404
  would leave a span open. Installed here, outside, the callback is already on
  that conn and the 404 settles like any other response.

  `router: PhoenixWeb.Router` is passed explicitly rather than being read from
  `conn.private[:phoenix_router]`, because on a request that never reached the
  router (a 404) that private key is never set -- and the milestone asks
  precisely that a routed request and a 404 be distinguishable.
  """

  use Plug.Builder

  plug(CodetracerBeamRecorder.Plug, framework: "phoenix", router: PhoenixWeb.Router)
  plug(PhoenixWeb.Endpoint)
end
