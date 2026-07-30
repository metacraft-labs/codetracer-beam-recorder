defmodule PlugWeb do
  @moduledoc """
  RS-M8 Plug/Cowboy demo driver.

  `main/0` starts a real Cowboy listener on an ephemeral port, drives real
  HTTP requests at it over TCP with `:httpc`, and shuts it down.  It is both
  the integration test's subject and the app `just demo-request-panel elixir`
  records, so the demo the developer opens in the GUI is the same session CI
  asserts on.

  Two schedules, selected by `CT_PLUG_WEB_SEQUENTIAL`:

    * **concurrent** (default) — a cohort of `CT_PLUG_WEB_COHORT` requests hits
      `/concurrent/:slot` and blocks on `PlugWeb.Barrier` until every one of
      them has arrived, so all of them are inside a handler simultaneously.
    * **sequential** (`CT_PLUG_WEB_SEQUENTIAL=1`) — cohort size 1 and one
      request at a time, so nothing overlaps.

  The second schedule exists so the concurrency assertion in
  `tests/integration/plug_requests_test.exs` is falsifiable: the same program,
  the same routes, the same recorder, and the spans' step ranges must stop
  overlapping.
  """

  @default_cohort 4

  def main do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:plug_cowboy)

    cohort = cohort_size()
    {:ok, _barrier} = PlugWeb.Barrier.start_link(cohort)

    {:ok, _} =
      Plug.Cowboy.http(PlugWeb.Endpoint, [],
        ref: __MODULE__.HTTP,
        port: 0,
        transport_options: [num_acceptors: 8]
      )

    port = :ranch.get_port(__MODULE__.HTTP)

    cohort_results = drive_cohort(port, cohort)
    sequential_results = drive_sequential(port)

    for {method, path, status} <- cohort_results ++ sequential_results do
      IO.puts("plug-web-request #{method} #{path} #{status}")
    end

    IO.puts(
      "plug-web-ok requests=#{length(cohort_results) + length(sequential_results)} " <>
        "cohort=#{cohort} port=#{port}"
    )

    :ok = Plug.Cowboy.shutdown(__MODULE__.HTTP)
  end

  # The cohort: `cohort` requests issued at once.  Each blocks in the handler
  # until all of them have arrived, so they are provably simultaneous.
  defp drive_cohort(port, cohort) do
    1..cohort
    |> Enum.map(fn slot ->
      Task.async(fn -> get(port, "/concurrent/#{slot}") end)
    end)
    |> Enum.map(&Task.await(&1, 30_000))
  end

  # The rest of the session: one request at a time, covering every status
  # bucket the panel colours plus a parameterised route and a POST.
  defp drive_sequential(port) do
    [
      get(port, "/api/users"),
      post(port, "/api/users", "name=hopper"),
      get(port, "/api/users/2"),
      get(port, "/static/app.css"),
      get(port, "/api/users/999"),
      get(port, "/slow"),
      get(port, "/boom"),
      get(port, "/healthz")
    ]
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

  defp cohort_size do
    cond do
      System.get_env("CT_PLUG_WEB_SEQUENTIAL") == "1" ->
        1

      value = System.get_env("CT_PLUG_WEB_COHORT") ->
        String.to_integer(value)

      true ->
        @default_cohort
    end
  end
end
