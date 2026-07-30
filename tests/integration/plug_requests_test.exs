ExUnit.start()

Code.require_file("support/span_stream_helpers.exs", __DIR__)

defmodule CodetracerBeamRecorder.PlugRequestsTest do
  use ExUnit.Case, async: false

  @moduledoc """
  RS-M8 — `plug_requests_land_in_span_stream`.

  Records `test-programs/elixir/plug_web`, a real `Plug.Router` served by a
  real Cowboy listener, and asserts the `.ct` container's own span stream. No
  sidecar JSONL is involved and none is consulted: the spans are decoded from
  `spans.dat` through the canonical Nim reader (`ct_spans_json`, reached via
  the recorder's `read-spans` subcommand), which is the decoder the shipped
  `ct print -f http` and the Request Panel's backend use.

  ## What this proves that a weaker test would not

  **One span per request, on the request's own BEAM process.** Cowboy spawns a
  process per connection and they run concurrently, so the interesting claim
  is not "twelve spans exist" but "twelve spans exist, each bound to the
  process that served it". Every span's `beam.pid` is asserted distinct, and
  cross-checked against `beam.thread_id` — the container thread that pid was
  mapped onto.

  **The concurrency bit is measured, not assumed.** The demo's
  `/concurrent/:slot` route blocks in a rendezvous until the whole cohort has
  arrived, so four requests are provably inside their handlers at the same
  instant and their step ranges must interleave. The same program is then
  recorded a second time with `CT_PLUG_WEB_SEQUENTIAL=1`, which sizes the
  rendezvous to one and issues the requests one at a time — and the test
  requires the overlap to disappear. Without that second recording,
  `concurrent_with_siblings: true` would be indistinguishable from a constant.

  ## Mocks

  None. A real recorder binary, a real `mix run`, a real Cowboy listener on an
  ephemeral port, real TCP requests from `:httpc`, a real `.ct` container and
  the production span decoder.
  """

  alias CodetracerBeamRecorder.SpanStreamHelpers, as: H

  @fixture_dir Path.join(H.repo_root(), "test-programs/elixir/plug_web")

  # The driver's schedule, transcribed from `PlugWeb.drive_cohort/2` and
  # `PlugWeb.drive_sequential/1`. Written out here rather than derived from
  # the recording, so a recorder bug cannot make the expectation agree with
  # itself.
  @cohort_size 4
  @sequential_requests [
    {"GET", "/api/users", 200, "/api/users"},
    {"POST", "/api/users", 201, "/api/users"},
    {"GET", "/api/users/2", 200, "/api/users/:user_id"},
    {"GET", "/static/app.css", 304, "/static/app.css"},
    {"GET", "/api/users/999", 404, "/api/users/:user_id"},
    {"GET", "/slow", 200, "/slow"},
    {"GET", "/boom", 500, "/boom"},
    {"GET", "/healthz", 200, "/healthz"}
  ]

  @moduletag timeout: 600_000

  test "plug_requests_land_in_span_stream" do
    build_root = H.tmp_dir!("rs-m8-plug-build")
    H.compile_demo!(@fixture_dir, build_root)

    out_dir = H.tmp_dir!("rs-m8-plug")
    output = H.record!(@fixture_dir, out_dir, "PlugWeb.main()", build_root: build_root)

    expected_count = @cohort_size + length(@sequential_requests)

    assert String.contains?(output, "plug-web-ok requests=#{expected_count} cohort=#{@cohort_size}"),
           "the demo must report its own schedule on stdout, got:\n#{output}"

    spans = H.read_spans!(out_dir)

    assert length(spans) == expected_count,
           "expected one settled span per request, got #{length(spans)}"

    for span <- spans do
      assert span["span_type"] == "web-request"
      assert span["is_open"] == false, "every request finished; none may stay in flight"

      assert span["is_external"] == false,
             "RS-M8 spans are inline-bound: the steps live in THIS container"

      assert span["process_ord"] == 0,
             "a BEAM recording is one OS process; requests are distinguished by thread"

      assert span["shares_timeline"] == true
      assert span["end_step"] >= span["start_step"]
      assert span["end_wall_ns"] >= span["start_wall_ns"]
      assert H.meta(span)["framework"] == "plug"
    end

    # --- one span per request, on its own BEAM process -------------------
    pids = Enum.map(spans, &H.meta(&1)["beam.pid"])

    assert Enum.all?(pids, &(&1 =~ ~r/^<\d+\.\d+\.\d+>$/)),
           "every span must name the BEAM process that served it, got #{inspect(pids)}"

    assert length(Enum.uniq(pids)) == expected_count,
           "Cowboy serves each request on its own process; #{expected_count} requests must " <>
             "give #{expected_count} distinct pids, got #{inspect(pids)}"

    thread_ids = Enum.map(spans, & &1["thread_id"])

    assert length(Enum.uniq(thread_ids)) == expected_count,
           "each BEAM process maps onto its own container thread, got #{inspect(thread_ids)}"

    for span <- spans do
      assert H.meta(span)["beam.thread_id"] == to_string(span["thread_id"]),
             "the metadata pid/thread pair must agree with the span's own coordinate"
    end

    # --- the cohort: provably simultaneous requests ----------------------
    {cohort, sequential} = Enum.split(spans, @cohort_size)

    cohort_urls = cohort |> Enum.map(&H.meta(&1)["http.url"]) |> Enum.sort()

    assert cohort_urls == Enum.map(1..@cohort_size, &"/concurrent/#{&1}"),
           "the first #{@cohort_size} spans are the rendezvous cohort, got #{inspect(cohort_urls)}"

    for span <- cohort do
      assert span["concurrent_with_siblings"] == true,
             "a rendezvous cohort member cannot have run alone: #{inspect(span)}"

      assert span["contiguous_on_one_thread"] == false,
             "with other requests interleaved into the shared exec stream, a cohort " <>
               "member's step range is not an uninterrupted run on one thread"
    end

    # Every pair genuinely overlaps, and no two spans are the same interval.
    for a <- cohort, b <- cohort, a["span_id"] < b["span_id"] do
      assert a["start_step"] <= b["end_step"] and b["start_step"] <= a["end_step"],
             "cohort spans #{a["span_id"]} and #{b["span_id"]} must overlap: " <>
               "#{a["start_step"]}..#{a["end_step"]} vs #{b["start_step"]}..#{b["end_step"]}"

      assert a["start_step"] != b["start_step"],
             "overlapping spans still occupy distinct coordinates"
    end

    # --- the sequential tail --------------------------------------------
    assert Enum.map(sequential, fn span ->
             m = H.meta(span)
             {m["http.method"], m["http.url"], String.to_integer(m["http.status_code"]),
              m["http.route"]}
           end) == @sequential_requests

    for span <- sequential do
      assert span["concurrent_with_siblings"] == false,
             "requests issued one at a time must not be reported as concurrent: #{inspect(span)}"
    end

    for [a, b] <- Enum.chunk_every(sequential, 2, 1, :discard) do
      assert b["start_step"] > a["end_step"],
             "sequential requests must occupy disjoint, ascending step ranges"
    end

    # `http.route` is the routed pattern, not the path the client typed.
    parameterised = Enum.find(sequential, &(H.meta(&1)["http.url"] == "/api/users/2"))
    assert H.meta(parameterised)["http.route"] == "/api/users/:user_id"
    assert H.meta(parameterised)["http.route"] != H.meta(parameterised)["http.url"]

    # Status is derived from the response, and the error buckets are real
    # responses rather than a colour someone chose.
    # Keyed by method AND url: `/api/users` is served by both a GET and a POST,
    # so a url-only key would silently drop one of them.
    by_url = Map.new(spans, &{{H.meta(&1)["http.method"], H.meta(&1)["http.url"]}, &1})
    assert by_url[{"GET", "/api/users/999"}]["status"] == 2, "a 404 is an error status"
    assert by_url[{"GET", "/boom"}]["status"] == 2, "a raising handler answered 500 is an error status"
    assert by_url[{"GET", "/healthz"}]["status"] == 1
    assert by_url[{"GET", "/static/app.css"}]["status"] == 1, "a 304 is not an error"

    # A 304 sends no body; a 200 does.
    assert H.meta(by_url[{"GET", "/static/app.css"}])["http.response_size"] == "0"
    assert String.to_integer(H.meta(by_url[{"GET", "/api/users"}])["http.response_size"]) > 0

    # `/slow` sleeps inside its handler, so it is the one row whose duration
    # must be more than "recorded and non-negative".
    slow_ms = String.to_integer(H.meta(by_url[{"GET", "/slow"}])["http.duration_ms"])
    healthz_ms = String.to_integer(H.meta(by_url[{"GET", "/healthz"}])["http.duration_ms"])

    assert slow_ms >= 400,
           "the /slow handler sleeps 400ms; its span must report at least that, got #{slow_ms}"

    assert slow_ms > healthz_ms, "the sleeping handler must outlast the trivial one"

    # Metadata order is part of the contract all the way to the panel.
    assert Enum.take(H.meta_keys(by_url[{"GET", "/healthz"}]), 3) == [
             "http.method",
             "http.url",
             "framework"
           ]

    # --- every request was published in flight before it settled ---------
    all_records = H.read_spans!(out_dir, :all)

    assert length(all_records) == expected_count * 2,
           "each span is appended twice — open, then settled — so a live panel can " <>
             "show an in-flight row; got #{length(all_records)} records"

    assert Enum.count(all_records, & &1["is_open"]) == expected_count

    # --- the falsifiability control --------------------------------------
    #
    # Same program, same routes, same recorder — one request at a time. If
    # `concurrent_with_siblings` were a constant rather than a measurement,
    # this half would pass with the cohort assertions above unchanged.
    sequential_out = H.tmp_dir!("rs-m8-plug-sequential")

    sequential_output =
      H.record!(@fixture_dir, sequential_out, "PlugWeb.main()",
        build_root: build_root,
        env: [{"CT_PLUG_WEB_SEQUENTIAL", "1"}, {"CT_PLUG_WEB_SLOW_MS", "10"}]
      )

    assert String.contains?(sequential_output, "plug-web-ok requests=9 cohort=1")

    sequential_spans = H.read_spans!(sequential_out)
    assert length(sequential_spans) == 9

    assert Enum.all?(sequential_spans, &(&1["concurrent_with_siblings"] == false)),
           """
           With a strictly sequential schedule NO span may be reported as concurrent.
           This is the control for the cohort assertions above; if it fails,
           `concurrent_with_siblings` is not measuring the schedule.

           #{inspect(Enum.map(sequential_spans, &{&1["span_id"], &1["start_step"], &1["end_step"], &1["concurrent_with_siblings"]}))}
           """

    for [a, b] <- Enum.chunk_every(sequential_spans, 2, 1, :discard) do
      assert b["start_step"] > a["end_step"],
             "a sequential schedule must produce disjoint, ascending step ranges"
    end

    assert Enum.any?(sequential_spans, & &1["contiguous_on_one_thread"]),
           """
           With nothing else in flight, a request's step range should be an
           uninterrupted run on its own thread, and at least one of these nine
           must show it. The cohort recording asserts the opposite for the same
           route, so between the two halves the bit is proven to take both values
           and to follow the schedule.

           It is `any?` rather than `all?` deliberately: the session gen_server
           serialises trace messages from every traced process, and a message
           the root process emitted before the request can still be processed
           during it, which legitimately interrupts that request's range. That
           is a measurement, not a defect, so the test does not pretend it
           cannot happen.

           #{inspect(Enum.map(sequential_spans, &{H.meta(&1)["http.url"], &1["contiguous_on_one_thread"]}))}
           """
  end
end
