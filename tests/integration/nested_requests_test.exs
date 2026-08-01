ExUnit.start()

Code.require_file("support/span_stream_helpers.exs", __DIR__)

defmodule CodetracerBeamRecorder.NestedRequestsTest do
  use ExUnit.Case, async: false

  @moduledoc """
  RS-M8 follow-up — `nested_requests_keep_the_outer_request_traced`.

  `CodetracerBeamRecorder.Plug`'s moduledoc claims that "a request handled
  inside another request" produces two independent spans, and the session's
  `open_spans` comment gives the reason it is keyed by span id rather than by
  pid: "a proxy-style handler can serve one request inside another". Until
  this suite, nothing exercised that path — every existing web suite drives
  requests that each get their own Cowboy process.

  The demo's `/proxy/:target` route serves a whole second request through the
  same endpoint pipeline, synchronously, **on the process already serving the
  outer request**. So one pid carries two open spans at once, which is exactly
  the state that separates per-span bookkeeping from per-pid bookkeeping.

  ## What this proves that a span-count assertion would not

  Two spans do come out even when the nesting is mishandled — `open_spans` is
  keyed by span id, so both markers get written and both spans settle. The
  claim that has teeth is that the OUTER request is still being recorded after
  the inner one finishes. `codetracer_session` turns `call` tracing on for a
  request's pid at `web_request_start` and off at `web_request_stop`, and that
  bookkeeping is per pid: a single non-nesting-aware "off" at the inner
  request's stop silences the outer request for the rest of its life.

  So the load-bearing assertion is on the recorded events themselves: the
  outer handler makes `@post_inner_calls` traced calls *after* its inner
  request has settled, and every one of them must appear in the recording,
  attributed to the outer request's pid, between the inner request's stop
  marker and the outer request's own. With per-pid disabling, that count is
  zero — the spans still look fine and the requests' bodies have vanished.

  ## Why the assertion is on the session stream and not on step indices

  A BEAM recording's span step range does not contain the handler's calls:
  under `mix run` Elixir sources carry no per-line step instrumentation, and
  `call`/`return_from` do not advance the container's exec-step counter, so a
  request's `start_step..end_step` is essentially the pair of synthetic
  `thread_switch` events bracketing it (measured here: the outer span covers
  14..17 with 30+ of its own call events inside). That is a known RS-M8
  limitation, tracked in the milestone as "Make Elixir step ranges resolve to
  handler source" — it is not what this suite is about, and asserting through
  it would make this test unfalsifiable. `runtime_session.jsonl` is the
  session's own recorded output (the same artifact `plug_smoke_test`,
  `message_trace_test` and `step_instrumentation_test` assert through), so
  what is checked here is genuinely what the recorder captured.

  ## Mocks

  None. A real recorder binary, a real `mix run`, a real Cowboy listener on an
  ephemeral port, a real TCP request, a real `.ct` container, and the
  production span decoder (`ct_spans_json`, via `read-spans`).
  """

  alias CodetracerBeamRecorder.SpanStreamHelpers, as: H

  @fixture_dir Path.join(H.repo_root(), "test-programs/elixir/plug_web")

  # Transcribed from `PlugWeb.Router.nested_work_calls/0`; passed explicitly so
  # this suite and the demo cannot drift apart silently.
  @post_inner_calls 25


  @moduletag timeout: 600_000

  test "nested_requests_keep_the_outer_request_traced" do
    build_root = H.tmp_dir!("rs-m8-nested-build")
    H.compile_demo!(@fixture_dir, build_root)

    out_dir = H.tmp_dir!("rs-m8-nested")

    output =
      H.record!(@fixture_dir, out_dir, "PlugWeb.main()",
        build_root: build_root,
        env: [
          {"CT_PLUG_WEB_NESTED", "1"},
          {"CT_PLUG_WEB_NESTED_CALLS", to_string(@post_inner_calls)}
        ]
      )

    assert String.contains?(output, "plug-web-nested-ok requests=1"),
           "the demo must report the nested schedule on stdout, got:\n#{output}"

    assert String.contains?(output, "plug-web-request GET /proxy/healthz 200"),
           "the outer request must have been answered over real TCP, got:\n#{output}"

    spans = H.read_spans!(out_dir)

    assert length(spans) == 2,
           "one outer and one inner request must produce two independent spans, got " <>
             "#{length(spans)}: #{inspect(Enum.map(spans, &H.meta(&1)["http.url"]))}"

    [outer, inner] = Enum.sort_by(spans, & &1["span_id"])

    assert H.meta(outer)["http.url"] == "/proxy/healthz"
    assert H.meta(inner)["http.url"] == "/healthz"

    # --- the nesting really is nesting ----------------------------------
    assert H.meta(outer)["beam.pid"] == H.meta(inner)["beam.pid"],
           "the inner request must be served on the outer request's own process, " <>
             "otherwise this is two sibling requests and proves nothing about nesting"

    assert outer["thread_id"] == inner["thread_id"],
           "same pid means same container thread"

    assert outer["start_step"] <= inner["start_step"] and inner["end_step"] <= outer["end_step"],
           "the inner span's step range must sit inside the outer's: " <>
             "#{inner["start_step"]}..#{inner["end_step"]} vs " <>
             "#{outer["start_step"]}..#{outer["end_step"]}"

    # --- both spans close, and close correctly --------------------------
    for span <- spans do
      assert span["span_type"] == "web-request"
      assert span["is_open"] == false, "both requests finished; neither may stay in flight"
      assert span["is_external"] == false
      assert span["end_step"] >= span["start_step"]
      assert span["end_wall_ns"] >= span["start_wall_ns"]
      assert H.meta(span)["http.status_code"] == "200"
    end

    assert H.meta(outer)["http.route"] == "/proxy/:target"
    assert H.meta(inner)["http.route"] == "/healthz"

    # --- the outer request is still recorded after the inner one ends ----
    events = session_events!(out_dir)
    pid = H.meta(outer)["beam.pid"]

    inner_stop = marker_index!(events, "web_request_stop", inner["span_id"])
    outer_stop = marker_index!(events, "web_request_stop", outer["span_id"])

    assert inner_stop < outer_stop,
           "the inner request must settle before the outer one, otherwise this recording " <>
             "is not the nesting the test set up"

    tail_calls =
      events
      |> Enum.slice((inner_stop + 1)..(outer_stop - 1)//1)
      |> Enum.filter(fn event ->
        event["event"] == "call" and event["pid"] == pid and
          event["module"] == "Elixir.PlugWeb.Nested" and event["function"] == "step_marker"
      end)
      |> length()

    assert tail_calls >= @post_inner_calls,
           "after the inner request settled, the outer handler called " <>
             "PlugWeb.Nested.step_marker/1 #{@post_inner_calls} times, but the recording " <>
             "holds #{tail_calls} such call(s) on #{pid} between the two stop markers. " <>
             "Zero is what a per-pid `call'-tracing disable at the inner request's stop " <>
             "looks like: the outer request stops being recorded the moment the inner one " <>
             "finishes, while its span still settles and still looks healthy."
  end

  # The session's own recorded output, as decoded events in emission order.
  defp session_events!(out_dir) do
    path = Path.join(out_dir, "runtime_session.jsonl")
    assert File.exists?(path), "expected the recorded session stream at #{path}"

    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&H.decode_json!/1)
  end

  defp marker_index!(events, event_name, span_id) do
    index =
      Enum.find_index(events, fn event ->
        event["event"] == event_name and event["span_id"] == span_id
      end)

    assert index != nil,
           "expected a #{event_name} marker for span #{span_id} in the session stream"

    index
  end
end
