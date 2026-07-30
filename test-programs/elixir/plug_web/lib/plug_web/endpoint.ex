defmodule PlugWeb.Endpoint do
  @moduledoc """
  The plug Cowboy serves.

  `CodetracerBeamRecorder.Plug` sits here, *outside* the router, for the same
  reason the Phoenix demo puts it outside the endpoint: `Plug.ErrorHandler`
  rescues with the conn that was in flight when the handler raised, and a
  `before_send` callback registered before the failing plug is still on that
  conn.  So `/boom` settles its span with the 500 the client actually
  received, instead of leaving an interval open because the handler died.
  """

  use Plug.Builder
  use Plug.ErrorHandler

  plug(CodetracerBeamRecorder.Plug, framework: "plug")
  plug(PlugWeb.Router)

  @impl Plug.ErrorHandler
  def handle_errors(conn, %{reason: reason}) do
    send_resp(conn, conn.status || 500, "handler failed: " <> inspect(reason))
  end
end
