defmodule PlugWeb.Nested do
  @moduledoc """
  The proxy-style handler behind `/proxy/:target`.

  `CodetracerBeamRecorder.Plug`'s moduledoc claims that "a request handled
  inside another request" comes out as two independent spans.  This module is
  what makes that claim executable: `serve_inner/1` runs a whole second
  request through the *same* endpoint pipeline, synchronously, **in the
  process that is already serving the outer request**.  That is the shape a
  real proxy/composition handler has, and it is the shape that makes the
  session's per-pid trace-flag bookkeeping matter — both requests share one
  pid, while their spans have different ids.

  `after_inner_work/1` exists purely so the outer request has *observable*
  work left to do after the inner one has settled: every `step_marker/1` call
  is a traced call event, so the outer span's step range has to keep growing
  after the inner span's end.  If the session turned the pid's `call' tracing
  off when the inner request finished, this work would leave no trace at all
  and the outer span would end one event after the inner one.
  """

  # A real second request through the real pipeline, on this process.
  # `Plug.Test.conn/3` is part of the `plug` package proper (not a test-only
  # dependency), and `send_resp/3` inside the router fires the `before_send`
  # callback the middleware registered, so the inner span settles exactly the
  # way a Cowboy-served one does.
  def serve_inner(path) do
    sent =
      Plug.Test.conn(:get, path)
      |> PlugWeb.Endpoint.call(PlugWeb.Endpoint.init([]))

    sent.status
  end

  def after_inner_work(count) do
    Enum.reduce(1..count, 0, fn index, acc -> acc + step_marker(index) end)
  end

  def step_marker(index) do
    index * 2
  end
end
