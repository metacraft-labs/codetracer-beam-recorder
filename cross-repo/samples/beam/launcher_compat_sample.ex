# Sample program for the launcher <-> recorder compatibility E2E.
#
# WHAT THIS IS FOR
#   `codetracer/ci/test/launcher-recorder-e2e.sh` records this file through the
#   REAL `ct` launcher binary:
#
#       ct record launcher_compat_sample.ex -o <trace-dir>
#         -> codetracer-launcher routes `.ex` from the codetracer-desktop
#            capability file and execv()s the desktop core
#            -> the core dispatches
#               `codetracer-beam-recorder record --out-dir <dir>
#                   --source-dir <this directory> -- elixir <program>`
#               -> the recorder instruments and runs it, writing a CTFS trace
#                  -> `ct-print` (codetracer-trace-format-nim) decodes it
#
#   The driver asserts the DECODED trace against the expectations declared in
#   `cross-repo/launcher-compat.yml`, so everything this file prints or calls is
#   part of a checked contract.  Changing a function name or a printed line here
#   means changing that file in the same commit.
#
# WHY IT LIVES IN A DIRECTORY OF ITS OWN
#   The desktop core derives the recorder's `--source-dir` from this file's
#   PARENT DIRECTORY (`program.parentDir` in
#   codetracer/src/ct/trace/recorder_dispatch.nim), and the recorder compiles
#   and bundles every BEAM source it finds there.  Keeping the negative-routing
#   sample and any future fixtures out of this directory keeps that set equal to
#   "this one file", which is what makes the driver's `--source-dir` check
#   ("the recorder bundled this file") exact.
#
# WHY IT PRINTS `CODETRACER_COMPONENT_DIR`
#   `CODETRACER_COMPONENT_DIR` is exported by the LAUNCHER and by nothing else
#   on this path (codetracer-launcher/src/launcher.nim sets it right before
#   `execv`-ing the component's binary).  Seeing it inside the recorded trace's
#   stdout is therefore positive evidence that the recording really travelled
#   launcher -> desktop core -> recorder, rather than the driver having invoked
#   the core (or the recorder) directly.  A test that only checked "a trace
#   appeared" could not tell those apart.
#
# KEEP THIS PROGRAM BORING
#   Fixed inputs, deterministic output, no clock, no network, no randomness, no
#   dependencies, no OTP application.  The trace it produces is compared against
#   exact expectations; anything non-deterministic would make the gate flaky.

defmodule LauncherCompatSample do
  @marker "launcher-recorder-e2e"

  # Fixed inputs -- the expected sum below is asserted by the driver.
  @values [1, 2, 3, 4, 5]

  # Sum `values` with an explicit reduction so the trace has real steps.
  def accumulate(values) do
    Enum.reduce(values, 0, fn value, total -> total + value end)
  end

  # Report the component directory the launcher exported for this run.
  def describe_launcher_route do
    case System.get_env("CODETRACER_COMPONENT_DIR") do
      nil -> "<unset>"
      value -> value
    end
  end

  def main do
    total = accumulate(@values)
    IO.puts("#{@marker}: total=#{total}")
    IO.puts("#{@marker}: component-dir=#{describe_launcher_route()}")
    total
  end
end

LauncherCompatSample.main()
