defmodule PhoenixWeb do
  @moduledoc """
  RS-M8 Phoenix demo driver.

  Starts the endpoint (with `server: false`), then serves
  `PhoenixWeb.TracedEndpoint` -- the CodeTracer plug wrapped around that
  endpoint -- on an ephemeral Cowboy listener, and drives real HTTP requests
  at it.

  The request schedule deliberately mixes:

    * routed requests whose `http.route` is a *pattern* with one or two
      parameters, so the panel can tell `/api/users/1` and `/api/users/2` are
      the same route;
    * a path that matches no route at all, which Phoenix answers with a 404
      through `Phoenix.Router.NoRouteError` and its own error renderer -- the
      case that has an empty `http.route`;
    * a handler that raises, answered with a 500;
    * a concurrent burst, so the Phoenix arm exercises several BEAM processes
      too.
  """

  def main do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:phoenix)
    {:ok, _} = Application.ensure_all_started(:plug_cowboy)
    {:ok, _endpoint} = PhoenixWeb.Endpoint.start_link()

    {:ok, _} =
      Plug.Cowboy.http(PhoenixWeb.TracedEndpoint, [],
        ref: __MODULE__.HTTP,
        port: 0,
        transport_options: [num_acceptors: 8]
      )

    port = :ranch.get_port(__MODULE__.HTTP)

    burst =
      ["/api/users/1", "/api/users/2", "/api/users/3"]
      |> Enum.map(fn path -> Task.async(fn -> get(port, path) end) end)
      |> Enum.map(&Task.await(&1, 30_000))

    sequential = [
      get(port, "/healthz"),
      get(port, "/api/users"),
      post(port, "/api/users", "name=hopper"),
      get(port, "/api/users/2"),
      get(port, "/api/reports/17/rows/4"),
      get(port, "/api/users/999"),
      get(port, "/does/not/exist"),
      get(port, "/api/boom")
    ]

    for {method, path, status} <- burst ++ sequential do
      IO.puts("phoenix-web-request #{method} #{path} #{status}")
    end

    IO.puts("phoenix-web-ok requests=#{length(burst) + length(sequential)} port=#{port}")

    :ok = Plug.Cowboy.shutdown(__MODULE__.HTTP)
  end

  defp get(port, path) do
    {:ok, {{_version, status, _reason}, _headers, _body}} =
      :httpc.request(:get, {url(port, path), []}, [{:timeout, 30_000}], [])

    {"GET", path, status}
  end

  defp post(port, path, body) do
    {:ok, {{_version, status, _reason}, _headers, _body}} =
      :httpc.request(
        :post,
        {url(port, path), [], ~c"application/x-www-form-urlencoded", String.to_charlist(body)},
        [{:timeout, 30_000}],
        []
      )

    {"POST", path, status}
  end

  defp url(port, path), do: String.to_charlist("http://127.0.0.1:#{port}#{path}")
end
