defmodule PlugWeb.Router do
  @moduledoc """
  The demo application's routes.

  Deliberately covers every status bucket the CodeTracer Request Panel
  colours (2xx, 3xx, 4xx, 5xx), two HTTP methods and a parameterised route,
  so the panel's rendering is exercised by a real recording rather than by a
  fixture someone typed.
  """

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  @users %{
    "1" => "ada",
    "2" => "grace",
    "3" => "barbara"
  }

  get "/healthz" do
    respond(conn, 200, "ok\n")
  end

  get "/api/users" do
    body = @users |> Map.values() |> Enum.sort() |> Enum.join(",")
    respond(conn, 200, body <> "\n")
  end

  post "/api/users" do
    respond(conn, 201, "created\n")
  end

  get "/api/users/:user_id" do
    case Map.fetch(@users, user_id) do
      {:ok, name} -> respond(conn, 200, name <> "\n")
      :error -> respond(conn, 404, "no such user\n")
    end
  end

  get "/static/app.css" do
    # A 3xx, so the panel's "redirect" colour bucket is covered by a real
    # response rather than by a synthetic row.
    respond(conn, 304, "")
  end

  get "/slow" do
    Process.sleep(slow_ms())
    respond(conn, 200, "slow\n")
  end

  # The rendezvous route.  Every request that reaches it blocks until the
  # barrier's whole cohort has arrived, so a cohort of N requests is
  # GUARANTEED to be in flight simultaneously — the spans' step ranges must
  # overlap, and cannot accidentally serialise on a fast machine.  With the
  # barrier sized to 1 (the driver's sequential mode) the same code path
  # produces a strictly sequential schedule, which is what makes the
  # concurrency assertion falsifiable.
  get "/concurrent/:slot" do
    :ok = PlugWeb.Barrier.arrive(slot)
    respond(conn, 200, "cohort " <> slot <> "\n")
  end

  # The nesting route.  The handler serves a whole second request through the
  # same endpoint, synchronously, on this very process — the "proxy-style
  # handler [that] can serve one request inside another" the session's
  # `open_spans` comment names.  It then does more traced work, so the outer
  # request's step range must keep growing after the inner span settles.
  get "/proxy/:target" do
    inner_status = PlugWeb.Nested.serve_inner("/" <> target)
    total = PlugWeb.Nested.after_inner_work(nested_work_calls())
    respond(conn, 200, "proxied #{inner_status} #{total}\n")
  end

  get "/boom" do
    _ = conn
    raise "demo handler failure"
  end

  match _ do
    respond(conn, 404, "not found\n")
  end

  defp respond(conn, status, body) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, body)
  end

  # How many traced calls the outer handler makes AFTER its inner request has
  # settled.  Transcribed by `tests/integration/nested_requests_test.exs`,
  # which requires the outer span to grow by at least this much minus slack.
  defp nested_work_calls do
    case System.get_env("CT_PLUG_WEB_NESTED_CALLS") do
      nil -> 25
      value -> String.to_integer(value)
    end
  end

  defp slow_ms do
    case System.get_env("CT_PLUG_WEB_SLOW_MS") do
      nil -> 400
      value -> String.to_integer(value)
    end
  end
end
