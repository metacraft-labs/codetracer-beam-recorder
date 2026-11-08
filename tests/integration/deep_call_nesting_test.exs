ExUnit.start()

defmodule CodetracerBeamRecorder.DeepCallNestingTest do
  use ExUnit.Case, async: false

  @moduledoc """
  A program whose calls nest deeply must be recorded in time roughly linear
  in the number of calls. `deep_calls:main/0` nests 30000 calls that all
  complete when the recursion unwinds; the recorder must exit, with a
  readable bundle, well inside the bound below.

  The bound is set from measurement: recording this fixture takes about
  35 s on a debug build when finishing the calls is linear, and several
  minutes when finishing them costs a pass over every completed call per
  call (the `stress_calls` fixture, 100000 calls, then ran for hours).
  No mocks: the real recorder binary records a real `erl`.
  """

  @repo_root Path.expand("../..", __DIR__)
  @fixture Path.join(@repo_root, "test-programs/erlang/deep_calls")
  @bound_ms 150_000
  @moduletag timeout: @bound_ms + 60_000

  test "e2e_runtime_deep_call_nesting_records_in_bounded_time" do
    out_dir = tmp_dir!("deep-calls")
    ebin_dir = tmp_dir!("deep-calls-ebin")
    src = Path.join(@fixture, "src/deep_calls.erl")

    {erlc_out, erlc_status} =
      System.cmd("erlc", ["+debug_info", "-o", ebin_dir, src], stderr_to_stdout: true)

    assert erlc_status == 0, "erlc #{src} failed: #{erlc_out}"

    args =
      ["record", "--out-dir", out_dir, "--", "erl", "-noshell", "-pa", ebin_dir] ++
        ["-s", "deep_calls", "main", "-s", "init", "stop"]

    port =
      Port.open({:spawn_executable, recorder_binary!()}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, args},
        {:cd, @fixture}
      ])

    os_pid = Port.info(port)[:os_pid]
    started = System.monotonic_time(:millisecond)
    {output, status} = await_exit(port, "", started + @bound_ms, os_pid)
    elapsed = System.monotonic_time(:millisecond) - started

    assert status != :timeout, """
    recording 30000 nested calls did not finish within #{@bound_ms} ms; the
    recorder was killed. Output so far:

    #{String.slice(output, -2000, 2000)}
    """

    assert status == 0, "recorder exited #{status} after #{elapsed} ms:\n#{output}"
    assert output =~ "deep-calls-ok 30000"

    {summary, summary_status} =
      System.cmd(recorder_binary!(), ["read-bundle-summary", "--bundle", out_dir],
        stderr_to_stdout: true
      )

    assert summary_status == 0, "read-bundle-summary failed:\n#{summary}"
    assert summary =~ ~s("sidecar_trace_delivered":true)
  end

  defp await_exit(port, acc, deadline, os_pid) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} -> await_exit(port, acc <> data, deadline, os_pid)
      {^port, {:exit_status, status}} -> {acc, status}
    after
      remaining ->
        # Kill the recorder and the BEAM it launched so nothing outlives the test.
        System.cmd("pkill", ["-KILL", "-P", Integer.to_string(os_pid)])
        System.cmd("kill", ["-KILL", Integer.to_string(os_pid)])
        {acc, :timeout}
    end
  end

  defp recorder_binary! do
    debug = Path.join([@repo_root, "target", "debug", "codetracer-beam-recorder"])
    release = Path.join([@repo_root, "target", "release", "codetracer-beam-recorder"])

    cond do
      override = System.get_env("CODETRACER_BEAM_RECORDER_BIN") ->
        File.exists?(override) ||
          flunk("CODETRACER_BEAM_RECORDER_BIN=#{override} does not exist")

        override

      File.exists?(debug) ->
        debug

      File.exists?(release) ->
        release

      true ->
        flunk("codetracer-beam-recorder binary not built; run cargo build --locked")
    end
  end

  defp tmp_dir!(label) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "codetracer-beam-recorder-#{label}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end
end
