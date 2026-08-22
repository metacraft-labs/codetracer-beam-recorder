# Known Limitations

This document collects the known gaps in the v1 BEAM recorder. Each
item is a feature that intentionally landed `implementation_partial`
in the milestones plan with a `:scope_deferred:` rationale; nothing
here is a silent regression. The follow-up work for each item is
tracked in [BEAM-Materialized-Trace-Recorder.milestones.org](
../../codetracer-specs/Planned-Work/BEAM-Materialized-Trace-Recorder.milestones.org).

## Single-file `elixir` recordings: module bodies run at build time

The `elixir <program>.ex` launch target compiles the program's module
definitions ahead of the recording so their abstract forms can be
instrumented, and runs only the file's top-level expressions inside the
recorded session. Consequences, in full:

- A module BODY (module attributes, `use` macros, anything evaluated
  while the module is being defined) runs during the build, not during
  the recording, and so does not appear in the trace. This is the same
  deviation Mix has.
- `__DIR__` and `__ENV__.file` inside *top-level* code refer to the
  generated entry script rather than to the original `.ex` file. Code
  inside modules is unaffected.
- An escript archive or a shebang script (anything the `escript` target
  is handed that is not a `.erl` source) is refused with a diagnostic
  rather than recorded uninstrumented.
- The recorder's copy of the program's stdout/stderr is appended to the
  trace after the runtime's own events rather than interleaved with
  them; the recorder shares no clock with the in-VM tracer.
- The recorded copy of that output is **normalised, not byte-exact**.
  Forwarding to the terminal is byte-for-byte, but the copy written into
  the trace is one event per line, decoded with `from_utf8_lossy`: a
  trailing `\r` is dropped from CRLF output and non-UTF-8 bytes become
  U+FFFD. Only the terminal sees a faithful byte stream.

Rationale, alternatives considered, and the exact split rules are in
[`launch-targets.md`](launch-targets.md).

## `escript` target: semantics not reproduced

`escript <program>.erl` is recorded by switching the launcher to
`erl -noshell -pa … -eval 'apply(Module, main, [Args])'` — `escript`
cannot be given a code path, so the instrumented ebin could not otherwise
be put in front of the script's own compilation
([`launch-targets.md` §3](launch-targets.md)). The entry-point contract
itself is faithful: `main/1` receives the same list of argument strings,
stdin passes through, and a value returned from `main/1` is ignored
exactly as `escript` ignores it. These *surrounding* behaviours belong to
the `escript` wrapper rather than to the emulator and are **not**
reproduced:

- **`halt/1` exit codes are lost.** A program whose `main/1` calls
  `halt(3)` exits 3 under `escript`. Under the recorder the emulator
  halts before the wrapper can stop the recording session, so the
  recorder reports `trace_write_failure`, exits **1**, and writes **no
  trace at all**. `halt/1` is the only way an escript can set its own
  exit code, so any script that uses it currently cannot be recorded.
- **The uncaught-exception exit code differs.** `escript` exits 127 with
  a one-line `escript: exception error: …` diagnostic. The recorder
  re-raises inside `erl -eval`, which exits **1**, prints the whole
  `-eval` expression to stderr, and leaves an `erl_crash.dump` in the
  working directory. The trace itself is written.
- **The script's own `%%!` emulator-flags line is ignored.** `escript`
  reads flags such as `-sname` from it; the recorder runs a fixed
  `erl -noshell` command line and never consults it. A script that
  depends on those flags (distribution, a named node, a custom heap
  setting) will behave differently.
- **`init:get_plain_arguments/0` omits the script path.** `escript`
  reports `["./prog.erl", "arg1", …]`; the recorder passes the arguments
  through `erl -extra` and so reports `["arg1", …]` without the leading
  script path.

## Windows: the BEAM launch targets are unverified

`target_program_name()` strips `.exe` / `.bat` / `.cmd` so that the
desktop core's `findExe`-resolved launchers (`elixir.bat`,
`escript.cmd`) are still classified as BEAM targets. That stripping is
covered by unit tests, but **no end-to-end `elixir` or `escript`
recording has ever been run on Windows** — there is no Windows BEAM
toolchain in this project's environments. Treat Windows support for
these two targets as untested rather than working.

## M16: optimized native tracer is a gen_server, not a real `erl_tracer` NIF

The M16 native backend (`--tracer-backend native`) ships as an Erlang
`gen_server` writer process rather than an `erl_tracer` NIF callback
module loaded via `erlang:load_nif/2`. This satisfies the M16
observable contract — atomic sequence ordering, parity with the
process backend, explicit overflow diagnostics, and a
`trace_delivered`-aware shutdown drain — but it is not the
sub-microsecond per-event NIF the spec aims for.

**What works:**

- `--tracer-backend native` runs and writes a sidecar with
  `"backend":"native"` markers.
- `counters`-based atomic sequence numbers stamped on every event.
- Explicit `block` (default) / `drop` overflow policy.
- `erlang:trace_delivered/1` shutdown barrier preserved.
- Native and process backends produce equivalent event sets through
  the reader (M16 parity test).

**What's deferred:**

- Real `erl_tracer` NIF callback module (Rust + `rustler`).
- `enabled_trace`, `enabled_call`, `enabled_send`, `enabled_receive`
  per-event filter callbacks (these require the NIF).
- Background C writer thread via `enif_thread_create`.
- `step` and `bind_many` events under native mode (M8/M9
  instrumentation paths only emit under process mode).

The M16 public API surface (`start_link/1`, `stop/2`,
`install_root_trace/2`, `event_count/0`, `dropped_count/0`,
`overflow_status/0`) is the seam the future NIF will replace
without churning `codetracer_session`.

## M15: GUI runtime CI gating

The M15 UI + VS Code smoke fixtures exercise the GUI surface against a
recorder-produced bundle. The CI matrix runs the GUI smoke tests under
the Nix dev shell on Linux only; macOS GUI runs are documented as
deferred (the GitHub-hosted macOS runners require a separate Webkit
bring-up that is out of scope for the M15 release-readiness cut).

**What works:**

- The reader-bridge round-trips a recorder bundle into the GUI's
  trace tab.
- The VS Code DAP bridge accepts the bundle and surfaces the call
  stack.

**What's deferred:**

- macOS GUI smoke matrix.
- A "headless reader bench" against a 100k-event bundle (currently
  covered indirectly by the M17 stress fixtures, but not as a
  dedicated reader benchmark).

## M17: Phoenix/Plug fixture

The Phoenix/Plug smoke fixture ships as a hand-rolled `:gen_tcp`
HTTP/1.1 server shaped like `Plug.Router`. The recorder dev shell is
offline, so we cannot pull the `:plug` Hex package as a dependency.

**What works:**

- Real BEAM, real Mix, real socket traffic.
- `record` exits 0; the bundle round-trips through the reader.
- The handler call sequence (`Router.route -> dispatch -> render`)
  is asserted in `tests/integration/plug_smoke_test.exs`.

**Resolved by RS-M8.** `test-programs/elixir/plug_web` (a real
`Plug.Router` on a real Cowboy listener) and
`test-programs/elixir/phoenix_web` (a real `Phoenix.Endpoint`, router
and controllers) now take `plug_cowboy` and `phoenix` from Hex, fetched
by `just prepare-web-fixtures`, and are recorded end to end by
`tests/integration/plug_requests_test.exs` and
`tests/integration/phoenix_requests_test.exs`. The offline `plug_smoke`
fixture is kept alongside them, not replaced: it is the one
request-shaped fixture that needs nothing from the network.

## M17: macOS CI matrix

The Linux ecosystem matrix covers `(OTP 26 + Elixir 1.16)` and
`(OTP 27 + Elixir 1.17)`. macOS coverage is documented in
`CHANGELOG.md` as deferred follow-up. macOS support is not blocked by
any recorder-internal limitation; the deferral is purely a CI runner
provisioning concern.

## Source-file parser for module/function discovery

The recorder discovers `(module, function, arity)` triples by reading
`*.ex` and `*.erl` files line-by-line. This is intentionally simple
but has known limitations:

- Multiple `defmodule` blocks in one `.ex` file: only the first is
  recognized. Workaround: split into one module per file (Phoenix /
  Mix's standard layout already does this).
- Function-head argument lists with commas inside literals (maps,
  tuples, lists) inflate the detected arity. Workaround: refactor
  the head to bind the arg name and pattern-match in the body
  (`def f(req) do x = req.foo; ... end`).

The full `erl_anno`-based discovery from `+debug_info` is the
followup; the source-file parser is the M0-era bootstrap path.
