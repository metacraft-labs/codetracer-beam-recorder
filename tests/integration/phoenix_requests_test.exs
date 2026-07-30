ExUnit.start()

Code.require_file("support/span_stream_helpers.exs", __DIR__)

defmodule CodetracerBeamRecorder.PhoenixRequestsTest do
  use ExUnit.Case, async: false

  @moduledoc """
  RS-M8 — `phoenix_requests_land_in_span_stream`.

  Records `test-programs/elixir/phoenix_web` — a real `Phoenix.Endpoint`,
  `Phoenix.Router` and controllers behind a real Cowboy listener — and asserts
  the container's span stream through the canonical Nim span reader.

  ## The two claims the milestone asks for

  **`http.route` is the routed pattern, not the raw path.** `/api/users/2` and
  `/api/users/3` must both record `"/api/users/:user_id"`; a two-parameter
  route must record both parameters. This is what lets the panel group rows by
  route instead of by URL, and it is only knowable from the router — which is
  why `CodetracerBeamRecorder.Plug` takes one.

  **A 404 is recorded, and is distinguishable from a routed response.**
  Phoenix answers an unmatched path by raising `Phoenix.Router.NoRouteError`
  and rendering it from `Phoenix.Endpoint`'s own error handler. The plug is
  installed *outside* the endpoint precisely so its `before_send` callback is
  still on the conn that error path sends; if it were installed inside, that
  request would leave an open span and this suite would fail on `is_open`.
  The unrouted 404 carries an empty `http.route`; a 404 the controller chose
  to return carries the route it matched — so the panel can tell "no such
  route" from "no such user".

  ## Mocks

  None. A real recorder binary, a real Phoenix app on an ephemeral port, real
  TCP requests, a real `.ct` container, the production span decoder.
  """

  alias CodetracerBeamRecorder.SpanStreamHelpers, as: H

  @fixture_dir Path.join(H.repo_root(), "test-programs/elixir/phoenix_web")

  # Transcribed from `PhoenixWeb.main/0` and `PhoenixWeb.Router`.
  @burst_paths ["/api/users/1", "/api/users/2", "/api/users/3"]
  @sequential_requests [
    {"GET", "/healthz", 200, "/healthz"},
    {"GET", "/api/users", 200, "/api/users"},
    {"POST", "/api/users", 201, "/api/users"},
    {"GET", "/api/users/2", 200, "/api/users/:user_id"},
    {"GET", "/api/reports/17/rows/4", 200, "/api/reports/:report_id/rows/:row_id"},
    {"GET", "/api/users/999", 404, "/api/users/:user_id"},
    {"GET", "/does/not/exist", 404, ""},
    {"GET", "/api/boom", 500, "/api/boom"}
  ]

  @moduletag timeout: 600_000

  test "phoenix_requests_land_in_span_stream" do
    build_root = H.tmp_dir!("rs-m8-phoenix-build")
    H.compile_demo!(@fixture_dir, build_root)

    out_dir = H.tmp_dir!("rs-m8-phoenix")
    output = H.record!(@fixture_dir, out_dir, "PhoenixWeb.main()", build_root: build_root)

    expected_count = length(@burst_paths) + length(@sequential_requests)

    assert String.contains?(output, "phoenix-web-ok requests=#{expected_count}"),
           "the demo must report its own schedule on stdout, got:\n#{output}"

    spans = H.read_spans!(out_dir)

    assert length(spans) == expected_count,
           "expected one settled span per request, got #{length(spans)}"

    for span <- spans do
      assert span["span_type"] == "web-request"

      assert span["is_open"] == false,
             """
             Every request, including the ones Phoenix answered from its error
             handler, must settle. An open span here means the plug's
             `before_send` callback did not survive the error path — the exact
             failure `PhoenixWeb.TracedEndpoint` exists to avoid.

             #{inspect(H.meta(span))}
             """

      assert span["is_external"] == false
      assert span["process_ord"] == 0
      assert span["shares_timeline"] == true
      assert H.meta(span)["framework"] == "phoenix"
      assert H.meta(span)["beam.pid"] =~ ~r/^<\d+\.\d+\.\d+>$/
      assert H.meta(span)["beam.thread_id"] == to_string(span["thread_id"])
    end

    pids = Enum.map(spans, &H.meta(&1)["beam.pid"])

    assert length(Enum.uniq(pids)) == expected_count,
           "Phoenix runs on Cowboy, one process per request: #{inspect(pids)}"

    {burst, sequential} = Enum.split(spans, length(@burst_paths))

    # --- the routed pattern, not the raw path ---------------------------
    burst_meta = Enum.map(burst, &H.meta/1)

    assert burst_meta |> Enum.map(& &1["http.url"]) |> Enum.sort() == Enum.sort(@burst_paths)

    assert Enum.all?(burst_meta, &(&1["http.route"] == "/api/users/:user_id")),
           """
           Three different URLs that matched the same route must record the same
           `http.route`; that is the whole point of recording the pattern.

           #{inspect(Enum.map(burst_meta, &{&1["http.url"], &1["http.route"]}))}
           """

    assert Enum.all?(burst_meta, &(&1["http.route"] != &1["http.url"])),
           "the route must be the pattern, not the path the client typed"

    assert Enum.map(sequential, fn span ->
             m = H.meta(span)

             {m["http.method"], m["http.url"], String.to_integer(m["http.status_code"]),
              m["http.route"]}
           end) == @sequential_requests

    # Keyed by method AND url: `/api/users` is served by both a GET and a POST,
    # so a url-only key would silently drop one of them.
    by_url = Map.new(spans, &{{H.meta(&1)["http.method"], H.meta(&1)["http.url"]}, &1})

    two_param = H.meta(by_url[{"GET", "/api/reports/17/rows/4"}])

    assert two_param["http.route"] == "/api/reports/:report_id/rows/:row_id",
           "both path parameters must be collapsed into the pattern"

    # --- the 404s --------------------------------------------------------
    unrouted = by_url[{"GET", "/does/not/exist"}]

    assert H.meta(unrouted)["http.status_code"] == "404"
    assert unrouted["status"] == 2, "a 404 is an error status"

    assert H.meta(unrouted)["http.route"] == "",
           """
           A path that matched no route has no routed pattern to report. An empty
           `http.route` is how the panel can tell this apart from a 404 a
           controller returned, which is asserted just below.
           """

    handler_404 = by_url[{"GET", "/api/users/999"}]
    assert H.meta(handler_404)["http.status_code"] == "404"

    assert H.meta(handler_404)["http.route"] == "/api/users/:user_id",
           "a 404 the controller chose still matched a route, and must say so"

    # --- statuses --------------------------------------------------------
    assert by_url[{"GET", "/api/boom"}]["status"] == 2
    assert H.meta(by_url[{"GET", "/api/boom"}])["http.status_code"] == "500"
    assert by_url[{"GET", "/healthz"}]["status"] == 1
    assert H.meta(by_url[{"GET", "/api/users"}])["http.status_code"] == "200"
    assert String.to_integer(H.meta(by_url[{"GET", "/api/users"}])["http.duration_ms"]) >= 0

    # --- open-then-settled ------------------------------------------------
    all_records = H.read_spans!(out_dir, :all)
    assert length(all_records) == expected_count * 2
    assert Enum.count(all_records, & &1["is_open"]) == expected_count

    # --- the structural bits describe THIS recording ----------------------
    #
    # `concurrent_with_siblings` must agree with the step ranges the same
    # container carries, for every span.  The deliberate proof that the bit
    # follows the schedule rather than being a constant lives in
    # `plug_requests_test.exs`, which records the same program twice under a
    # rendezvous and under a strictly sequential driver; here the claim is the
    # weaker but fully deterministic one that the recorder cannot report an
    # overlap the ranges do not show, or miss one they do.
    for span <- spans do
      overlaps =
        Enum.any?(spans, fn other ->
          other["span_id"] != span["span_id"] and
            other["start_step"] <= span["end_step"] and
            span["start_step"] <= other["end_step"]
        end)

      assert span["concurrent_with_siblings"] == overlaps,
             "span #{span["span_id"]} claims concurrent=#{span["concurrent_with_siblings"]} " <>
               "but its range #{span["start_step"]}..#{span["end_step"]} says #{overlaps}"
    end

    for [a, b] <- Enum.chunk_every(sequential, 2, 1, :discard) do
      assert b["start_step"] > a["end_step"],
             "requests issued one at a time must occupy disjoint, ascending step ranges"
    end
  end
end
