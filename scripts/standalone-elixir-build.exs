# Standalone (Mix-less) Elixir build driver for the `elixir <program>.ex`
# launch target.
#
# `codetracer-beam-recorder record ... -- elixir foo.ex` cannot reach
# `mix compile.codetracer`: there is no Mix project.  The recorder therefore
# runs THIS script under the same `elixir` binary it is about to hand the
# program to, so the instrumented modules and the CodeTracer runtime app are
# compiled by the very OTP/Elixir pair that will load them.
#
# Argument: the path to a JSON build spec written by the recorder
# (`codetracer.beam.standalone-elixir-spec.v1`):
#
#   {"build_dir": ..., "source_root": ..., "sources": [...],
#    "runtime_ebin": ..., "summary_path": ...,
#    "include_modules": [...], "exclude_modules": [...]}
#
# On success it writes `summary_path` — a `codetracer.beam.standalone-build.v1`
# summary extended with `elixir_entries` — and exits 0.  Any failure raises,
# which exits non-zero with a diagnostic: this script must never report
# success without having instrumented something, because a silently empty
# build is exactly the defect the `elixir` launch target exists to fix.

case System.argv() do
  [spec_path] ->
    Application.ensure_all_started(:mix)

    Code.require_file(
      Path.expand("../lib/codetracer_beam_recorder/elixir_source_map.ex", __DIR__)
    )

    summary = CodetracerBeamRecorder.ElixirSourceMap.build_standalone_from_spec!(spec_path)

    IO.puts(
      "codetracer: standalone Elixir build instrumented " <>
        "#{length(summary.trace_functions)} traceable functions into #{summary.instrumented_ebin}"
    )

  other ->
    IO.puts(:stderr, "usage: standalone-elixir-build.exs <spec.json> (got #{inspect(other)})")
    System.halt(2)
end
