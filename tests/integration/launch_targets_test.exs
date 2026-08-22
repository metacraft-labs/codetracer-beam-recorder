ExUnit.start()

defmodule CodetracerBeamRecorder.LaunchTargetsTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Verification for the `elixir` and `escript` launch targets — the two launch
  commands the CodeTracer desktop core builds for a SINGLE-FILE recording
  (`codetracer/src/ct/trace/recorder_dispatch.nim`: `-- elixir <program>` for
  `LangElixir`, `-- escript <program>` for `LangErlang`).

  Before these targets existed, `ct record foo.ex` reached this recorder as
  `-- elixir foo.ex`, `is_beam_target()` classified it NON-BEAM, and the
  recorder exited 0 having written a 2-event, 0-function trace while the
  program itself ran and printed normally. That is the exact shape
  `codetracer-specs/CLI/ct/record.md` forbids:

      "The recorder produced no trace but exited 0. Treat as a failure. A
       missing trace with a success exit is the silent-incompleteness
       pattern."

  So these tests assert on the DECODED TRACE SHAPE — interned functions,
  paired call records, steps, and the program's own recorded stdout — never
  merely that a trace file appeared. And they assert that every way of
  reaching an empty recording now fails LOUDLY, with a diagnostic that names
  the reason.

  Everything here uses the real recorder binary, the real BEAM toolchain and
  the real CTFS reader (through `read-bundle-summary`, which wraps the same
  `NimTraceReaderHandle` the GUI uses). There are no mocks, fakes or stubs,
  and no skips: a missing `elixir` / `erl` / `escript` toolchain must fail
  loudly. `tests/verify-launch-targets-test-no-silent-skip.sh` guards that.

  Design: docs/launch-targets.md.
  """

  @repo_root Path.expand("../..", __DIR__)
  @elixir_program Path.join(
                    @repo_root,
                    "test-programs/elixir/standalone_script/standalone_script.ex"
                  )
  @elixir_source_dir Path.join(@repo_root, "test-programs/elixir/standalone_script")
  @erlang_program Path.join(
                    @repo_root,
                    "test-programs/erlang/escript_program/escript_program.erl"
                  )
  @erlang_source_dir Path.join(@repo_root, "test-programs/erlang/escript_program")

  setup_all do
    require_toolchain!(["elixir", "elixirc", "erl", "erlc", "escript"])
    :ok
  end

  # ------------------------------------------------------------------
  # Happy paths
  # ------------------------------------------------------------------

  test "elixir_launch_target_records_a_bare_ex_program" do
    out_dir = tmp_dir!("elixir-target")
    cwd = tmp_dir!("elixir-target-cwd")

    {output, status} =
      record!(cwd, [
        "--out-dir",
        out_dir,
        "--source-dir",
        @elixir_source_dir,
        "--",
        "elixir",
        @elixir_program
      ])

    assert status == 0, "`-- elixir <program>.ex` must record successfully:\n#{output}"

    summary = read_bundle_summary!(out_dir)
    meta = read_trace_meta!(out_dir)

    # The defect's fingerprint was `"mode": "non_beam"` with an empty
    # `sources` list. Both must now be the opposite.
    assert meta["runtime_session"]["mode"] == "beam",
           "trace_meta.json must report a BEAM mode, got #{inspect(meta["runtime_session"]["mode"])}"

    assert meta["sources"] != [],
           "trace_meta.json `sources` must not be empty: --source-dir exists to bundle the program"

    assert summary["language"] == "elixir"
    assert summary["runtime_session_mode"] == "beam"
    assert summary["runtime_session_delivered"] == true
    assert summary["target_exit_code"] == 0

    for name <- [
          "StandaloneScript.main/0",
          "StandaloneScript.accumulate/1",
          "StandaloneScript.describe/0"
        ] do
      assert name in summary["function_names"],
             "function table must contain #{name}; got #{inspect(summary["function_names"])}"
    end

    assert summary["call_count"] >= 3,
           "expected at least 3 paired call records, got #{summary["call_count"]}"

    assert summary["step_count"] > 0,
           "an instrumented recording must contain steps, got #{summary["step_count"]}"

    assert summary["sidecar_call_count"] >= 3,
           "the runtime sidecar must have seen the calls before the writer did, got #{summary["sidecar_call_count"]}"

    # The program's own output, read back OUT OF THE TRACE. This is what
    # distinguishes "the recorder captured the run" from "the recorder
    # accompanied the run" — the original defect looked identical on the
    # terminal.
    recorded = recorded_output(summary)

    assert "standalone-script: total=15" in recorded,
           "the recorded trace must contain the program's stdout; got #{inspect(recorded)}"

    assert "standalone-script: describe=elixir-launch-target" in recorded,
           "the recorded trace must contain the program's stdout; got #{inspect(recorded)}"

    # The program must still print for real, exactly once.
    assert length(String.split(output, "standalone-script: total=15")) == 2,
           "the program must print its output exactly once, not zero or twice:\n#{output}"
  end

  test "escript_launch_target_records_a_bare_erl_program" do
    out_dir = tmp_dir!("escript-target")
    cwd = tmp_dir!("escript-target-cwd")

    {output, status} =
      record!(cwd, [
        "--out-dir",
        out_dir,
        "--source-dir",
        @erlang_source_dir,
        "--",
        "escript",
        @erlang_program
      ])

    assert status == 0, "`-- escript <program>.erl` must record successfully:\n#{output}"

    summary = read_bundle_summary!(out_dir)
    meta = read_trace_meta!(out_dir)

    assert meta["runtime_session"]["mode"] == "beam"
    assert meta["sources"] != []

    # `escript` implies Erlang: the core only dispatches it for `.erl`/`.hrl`.
    assert summary["language"] == "erlang",
           "the escript target must record Erlang, got #{inspect(summary["language"])}"

    assert summary["runtime_session_delivered"] == true
    assert summary["target_exit_code"] == 0

    for name <- [
          "escript_program:main/1",
          "escript_program:accumulate/1",
          "escript_program:accumulate/2",
          "escript_program:describe/0"
        ] do
      assert name in summary["function_names"],
             "function table must contain #{name}; got #{inspect(summary["function_names"])}"
    end

    assert summary["call_count"] >= 4,
           "expected at least 4 paired call records (main + the recursive accumulate), got #{summary["call_count"]}"

    assert summary["step_count"] > 0

    recorded = recorded_output(summary)

    assert "escript-program: total=15" in recorded,
           "the recorded trace must contain the program's stdout; got #{inspect(recorded)}"

    assert "escript-program: describe=escript-launch-target" in recorded,
           "the recorded trace must contain the program's stdout; got #{inspect(recorded)}"
  end

  # ------------------------------------------------------------------
  # The guard: no BEAM target may exit 0 having recorded nothing
  # ------------------------------------------------------------------

  test "guard_uninstrumentable_source_dir_fails_loudly" do
    out_dir = tmp_dir!("guard-empty-source-dir")
    cwd = tmp_dir!("guard-empty-source-dir-cwd")
    empty = tmp_dir!("guard-empty-source-dir-src")

    {output, status} =
      record!(cwd, [
        "--out-dir",
        out_dir,
        "--source-dir",
        empty,
        "--",
        "elixir",
        @elixir_program
      ])

    assert status != 0,
           "a --source-dir with nothing to instrument must FAIL, not produce an empty recording:\n#{output}"

    assert output =~ "no BEAM sources were compiled into an instrumented ebin",
           "the failure must name why nothing was instrumented; got:\n#{output}"

    assert output =~ empty, "the diagnostic must name the directory it searched; got:\n#{output}"
  end

  test "guard_missing_source_dir_fails_loudly" do
    out_dir = tmp_dir!("guard-no-source-dir")
    cwd = tmp_dir!("guard-no-source-dir-cwd")

    {output, status} =
      record!(cwd, ["--out-dir", out_dir, "--", "elixir", @elixir_program])

    assert status != 0,
           "a BEAM target with no discoverable sources must FAIL, not record an empty trace:\n#{output}"

    assert output =~ "produced no traceable functions",
           "the failure must say the recording would have been empty; got:\n#{output}"

    assert output =~ "--source-dir",
           "the failure must point at the flag that fixes it; got:\n#{output}"
  end

  test "guard_uninstrumented_program_fails_loudly" do
    # Something IS instrumented — just not the program being recorded.
    out_dir = tmp_dir!("guard-wrong-program")
    cwd = tmp_dir!("guard-wrong-program-cwd")

    {output, status} =
      record!(cwd, [
        "--out-dir",
        out_dir,
        "--source-dir",
        @erlang_source_dir,
        "--",
        "elixir",
        @elixir_program
      ])

    assert status != 0,
           "recording a program that was not instrumented must FAIL:\n#{output}"

    assert output =~ "was not part of the instrumented standalone Elixir build",
           "the failure must name the program that is missing; got:\n#{output}"
  end

  test "escript_launch_target_passes_script_arguments_to_main" do
    # `escript prog.erl a b` calls `prog:main(["a", "b"])` — a list of
    # STRINGS. The recorder reproduces that through
    # `erl -eval 'apply(Module, main, [Args])'`, and nothing else in this
    # suite exercises it: the happy-path fixture's `main(_Args)` ignores its
    # argument, so a mutation that always passed `[]` survived every test.
    out_dir = tmp_dir!("escript-args")
    cwd = tmp_dir!("escript-args-cwd")
    src = tmp_dir!("escript-args-src")

    program = Path.join(src, "argv_echo.erl")

    File.write!(program, """
    -module(argv_echo).
    -export([main/1]).
    main(Args) ->
        io:format("argv-count=~p~n", [length(Args)]),
        io:format("argv-all-strings=~p~n", [lists:all(fun erlang:is_list/1, Args)]),
        io:format("argv=~s~n", [string:join(Args, ",")]).
    """)

    {output, status} =
      record!(cwd, [
        "--out-dir",
        out_dir,
        "--source-dir",
        src,
        "--",
        "escript",
        program,
        "alpha",
        "beta"
      ])

    assert status == 0, "recording an escript with arguments must succeed:\n#{output}"

    recorded = recorded_output(read_bundle_summary!(out_dir))

    assert "argv-count=2" in recorded,
           "main/1 must receive both script arguments; got #{inspect(recorded)}"

    assert "argv-all-strings=true" in recorded,
           "escript hands main/1 a list of STRINGS; got #{inspect(recorded)}"

    assert "argv=alpha,beta" in recorded,
           "the arguments must arrive in order and unmodified; got #{inspect(recorded)}"
  end

  test "elixir_launch_target_compiles_modules_with_their_top_level_directives" do
    # The AST split sends `defmodule` forms to `Code.compile_quoted/2` and
    # everything else to the entry script — but a module can DEPEND on a
    # top-level `alias` / `import` / `require`, so those directives have to be
    # prepended to the compilation unit too. Nothing else in any suite covers
    # that: a mutation dropping the directives from the compile survived the
    # whole suite. The alias here is load-bearing — `Helper` resolves only
    # through it.
    out_dir = tmp_dir!("elixir-directives")
    cwd = tmp_dir!("elixir-directives-cwd")
    src = tmp_dir!("elixir-directives-src")

    program = Path.join(src, "uses_alias.ex")

    File.write!(program, """
    alias Standalone.Nested.Helper
    import Bitwise

    defmodule Standalone.Nested.Helper do
      def value, do: "aliased-helper"
    end

    defmodule UsesAlias do
      def go, do: Helper.value()
      def masked, do: 6 &&& 3
    end

    IO.puts("directives: \#{UsesAlias.go()}/\#{UsesAlias.masked()}")
    """)

    {output, status} =
      record!(cwd, ["--out-dir", out_dir, "--source-dir", src, "--", "elixir", program])

    assert status == 0,
           "a module depending on a top-level alias/import must still compile:\n#{output}"

    summary = read_bundle_summary!(out_dir)

    assert "directives: aliased-helper/2" in recorded_output(summary),
           "the aliased and imported calls must resolve; got #{inspect(recorded_output(summary))}"

    for name <- ["UsesAlias.go/0", "Standalone.Nested.Helper.value/0"] do
      assert name in summary["function_names"],
             "function table must contain #{name}; got #{inspect(summary["function_names"])}"
    end
  end

  test "guard_instrumented_ebin_without_traceable_functions_fails_loudly" do
    # The last of the four guards in docs/launch-targets.md §6: modules DID
    # compile and an instrumented ebin DID appear, but it declares no
    # traceable function, so the recording would describe the program's
    # lifecycle and nothing else. Nothing else in any suite reaches this arm.
    out_dir = tmp_dir!("guard-no-traceable-fns")
    cwd = tmp_dir!("guard-no-traceable-fns-cwd")
    src = tmp_dir!("guard-no-traceable-fns-src")

    program = Path.join(src, "only_attributes.ex")

    File.write!(program, """
    defmodule OnlyAttributes do
      @moduledoc "a module that defines no functions at all"
    end

    IO.puts("this program has nothing to trace")
    """)

    {output, status} =
      record!(cwd, ["--out-dir", out_dir, "--source-dir", src, "--", "elixir", program])

    assert status != 0,
           "an instrumented ebin with no traceable functions must FAIL, not record an empty trace:\n#{output}"

    assert output =~ "contains no traceable functions",
           "the failure must say the recording would have been empty; got:\n#{output}"
  end

  test "guard_module_defined_inside_a_top_level_expression_fails_loudly" do
    # A `defmodule` nested in a top-level expression is not a top-level module
    # form, so the AST split would leave it in the entry script and compile it
    # at RECORD time — uninstrumented. When the file ALSO defines a top-level
    # module, every "nothing was instrumented" guard still passes and the
    # recording silently describes only half the program. That must fail.
    out_dir = tmp_dir!("guard-conditional-module")
    cwd = tmp_dir!("guard-conditional-module-cwd")
    src = tmp_dir!("guard-conditional-module-src")

    program = Path.join(src, "conditional_module.ex")

    File.write!(program, """
    defmodule Visible do
      def visible, do: "visible"
    end

    if true do
      defmodule Hidden do
        def hidden, do: "hidden"
      end
    end

    IO.puts("\#{Visible.visible()}/\#{Hidden.hidden()}")
    """)

    {output, status} =
      record!(cwd, ["--out-dir", out_dir, "--source-dir", src, "--", "elixir", program])

    assert status != 0,
           "a module defined inside a top-level expression must FAIL, not be silently left out of the recording:\n#{output}"

    assert output =~ "inside a top-level expression",
           "the failure must name the reason; got:\n#{output}"

    assert output =~ "Hidden",
           "the failure must name the module it cannot instrument; got:\n#{output}"
  end

  test "guard_escript_without_erl_source_fails_loudly" do
    out_dir = tmp_dir!("guard-escript-archive")
    cwd = tmp_dir!("guard-escript-archive-cwd")

    {output, status} =
      record!(cwd, [
        "--out-dir",
        out_dir,
        "--source-dir",
        @erlang_source_dir,
        "--",
        "escript",
        Path.join(cwd, "packaged.escript")
      ])

    assert status != 0, "an escript with no `.erl` source must FAIL:\n#{output}"

    assert output =~ "only records `.erl` sources",
           "the failure must name the restriction; got:\n#{output}"
  end

  test "non_beam_targets_still_run_verbatim_and_propagate_exit_codes" do
    # The guard must not fire for a non-BEAM command: `record -- sh -c ...`
    # is a documented use and still propagates the target's exit code.
    out_dir = tmp_dir!("non-beam-passthrough")
    cwd = tmp_dir!("non-beam-passthrough-cwd")

    {output, status} =
      record!(cwd, ["--out-dir", out_dir, "--", "sh", "-c", "printf passthrough; exit 7"])

    assert status == 7,
           "a non-BEAM target must still propagate its exit code, got #{status}:\n#{output}"

    assert output =~ "passthrough",
           "a non-BEAM target's output must still reach the terminal; got:\n#{output}"

    meta = read_trace_meta!(out_dir)
    assert meta["runtime_session"]["mode"] == "non_beam"
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp record!(cwd, args) do
    System.cmd(recorder_binary!(), ["record" | args], cd: cwd, stderr_to_stdout: true)
  end

  defp recorded_output(summary) do
    summary
    |> Map.get("recorded_output", [])
    |> Enum.map(fn entry -> entry["text"] end)
  end

  defp require_toolchain!(binaries) do
    missing = Enum.reject(binaries, &System.find_executable/1)

    if missing != [] do
      # Deliberately a FAILURE, never a skip: this repo's ecosystem has
      # already shipped several silent-skip defects, and a launch-target
      # suite that quietly does nothing is worse than no suite at all.
      flunk("""
      the BEAM toolchain is required for the launch-target suite and is missing: #{Enum.join(missing, ", ")}

      Run this suite inside the repo's dev shell (`nix develop` / `direnv exec .`).
      """)
    end

    :ok
  end

  defp read_bundle_summary!(out_dir) do
    {output, status} =
      System.cmd(recorder_binary!(), ["read-bundle-summary", "--bundle", out_dir],
        stderr_to_stdout: true
      )

    assert status == 0, "read-bundle-summary failed with status #{status}\n\n#{output}"

    output
    |> String.split("\n", trim: true)
    |> List.last()
    |> decode_json!()
  end

  defp read_trace_meta!(out_dir) do
    path = Path.join(out_dir, "trace_meta.json")
    assert File.regular?(path), "the recorder must write #{path}"

    path |> File.read!() |> decode_json!()
  end

  # OTP 27+ ships `:json`, which is what the recorder's own Elixir code uses
  # through `JasonCompat`. `null` decodes as `:null`; nothing here compares
  # against nil, so no normalisation is needed.
  defp decode_json!(text), do: :json.decode(text)

  defp recorder_binary! do
    case System.get_env("CODETRACER_BEAM_RECORDER_BIN") do
      nil ->
        debug = Path.join([@repo_root, "target", "debug", "codetracer-beam-recorder"])
        release = Path.join([@repo_root, "target", "release", "codetracer-beam-recorder"])

        cond do
          File.exists?(debug) ->
            debug

          File.exists?(release) ->
            release

          true ->
            flunk("""
            codetracer-beam-recorder binary not found in target/debug or target/release.
            Build it via `cargo build --locked` first, or set CODETRACER_BEAM_RECORDER_BIN.
            """)
        end

      override ->
        File.exists?(override) ||
          flunk("CODETRACER_BEAM_RECORDER_BIN=#{override} does not exist")

        override
    end
  end

  defp tmp_dir!(label) do
    nonce = System.unique_integer([:positive])
    stamp = System.system_time(:nanosecond)

    path =
      Path.join(
        System.tmp_dir!(),
        "codetracer-beam-recorder-launch-targets-#{label}-#{stamp}-#{nonce}"
      )

    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
