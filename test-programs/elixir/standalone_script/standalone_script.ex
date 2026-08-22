# Fixture for the `elixir <program>.ex` launch target.
#
# `ct record foo.ex` makes the CodeTracer desktop core dispatch
#   codetracer-beam-recorder record --out-dir D --source-dir S -- elixir foo.ex
# (src/ct/trace/recorder_dispatch.nim, LangElixir).  There is no Mix project
# here on purpose: this file is the whole program, exactly as a user's
# throwaway script would be.
#
# It has the shape the standalone build must cope with — MODULE DEFINITIONS
# followed by TOP-LEVEL EXPRESSIONS.  The recorder compiles and instruments
# the former ahead of time and runs the latter as the recording's entry
# point; see docs/launch-targets.md.
#
# KEEP THIS PROGRAM BORING: fixed inputs, deterministic output, no clock, no
# randomness, no dependencies.  The recorded trace is asserted against exact
# expectations in tests/integration/launch_targets_test.exs.

defmodule StandaloneScript do
  @values [1, 2, 3, 4, 5]

  def accumulate(values) do
    Enum.reduce(values, 0, fn value, total -> total + value end)
  end

  def describe do
    "elixir-launch-target"
  end

  def main do
    total = accumulate(@values)
    IO.puts("standalone-script: total=#{total}")
    IO.puts("standalone-script: describe=#{describe()}")
    total
  end
end

StandaloneScript.main()
