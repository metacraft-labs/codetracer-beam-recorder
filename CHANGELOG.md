# Changelog

All notable changes to the CodeTracer BEAM materialized trace recorder
are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions are SemVer; the canonical version lives in `Cargo.toml`.

## [Unreleased]

### Added

- `elixir` and `escript` launch targets. `record -- elixir <program>.ex`
  and `record -- escript <program>.erl` are now instrumented and
  recorded, which is what `ct record foo.ex` / `ct record foo.erl`
  dispatch through the CodeTracer desktop core. A bare `.ex` program is
  compiled outside Mix by splitting its module definitions from its
  top-level entry code and instrumenting the former through the same
  `codetracer_forms` abstract-forms transform `mix compile.codetracer`
  uses. Specified in `docs/launch-targets.md`.
- Recorded program output. The recorder now forwards the target's
  stdout and stderr byte for byte AND writes a copy into the trace, so
  "what did this run print?" is answerable from the trace alone.
  `read-bundle-summary` surfaces it as `recorded_output`. The copy in
  the trace is one event per line and lossy-UTF-8 decoded, so it is not
  a faithful transcript of binary output — see
  `docs/known-limitations.md`.
- RS-M8: web-request spans. `CodetracerBeamRecorder.Plug` records one
  span per HTTP request directly into the recording's `.ct` container —
  no sidecar file — with the owning BEAM process id in metadata.
  Phoenix apps additionally get `http.route` resolved from the router,
  so a row shows the pattern the request matched rather than the path
  the client typed.
- RS-M8: `codetracer-beam-recorder read-spans --bundle DIR [--all]`
  prints a recorded bundle's span stream as JSON, decoded through the
  canonical Nim span reader.
- RS-M8: `test-programs/elixir/plug_web` and
  `test-programs/elixir/phoenix_web` demo apps, driven end to end by
  `tests/integration/plug_requests_test.exs` and
  `tests/integration/phoenix_requests_test.exs`, plus
  `just demo-request-panel-elixir` and
  `just record-request-panel-fixture`.

### Fixed

- Recorded `.ct` files are decodable by `ct print` again. The low-level
  supplement (`DropVariables` and the raw `Value` records, which the Nim
  multi-stream writer's C API cannot express) was appended into the
  recording's own container as a legacy combined `events.log`; `ct print`
  diverts to its legacy reader for any container carrying one, and then
  failed with `chunk compressed data extends beyond events.log`. Every
  instrumented BEAM recording — `erl` and `rebar3` included — was
  affected. The supplement now lives in
  `recorder_metadata/low_level_events.ctfs`. See `docs/ctfs-output.md`.
- A BEAM launch target can no longer produce a successful-looking empty
  recording. `record -- elixir foo.ex` used to exit 0 with a
  `"mode": "non_beam"` trace containing 2 events, 0 functions and 0
  calls, while the program itself ran and printed normally. Every way of
  reaching an uninstrumented BEAM recording now exits non-zero with a
  diagnostic naming the cause — see `docs/launch-targets.md` §6.
- A `.ex` program that defines a module inside a top-level expression
  (`if … do defmodule … end end`, a comprehension, a `case` arm) is
  refused instead of being partially recorded. Such a module is not a
  top-level form, so it would have been compiled while the program ran
  and recorded uninstrumented; when the file also defined a module at
  the top level, every "nothing was instrumented" guard still passed and
  the recording silently described half the program. `quote` blocks are
  exempt.

### Notes

- A BEAM process is mapped onto a container **thread**, not a container
  process: a recording is one OS process, so every web-request span
  carries `process_ord = 0` and the thread id its pid was assigned.
- The three structural bits are measured from the recording rather than
  declared. Requests that overlap carry `concurrent_with_siblings` and
  are not `contiguous_on_one_thread`, because the recorder replays its
  session into a single exec stream in which their events interleave.


## [0.1.0] - 2026-05-08

This is the M17 release-hardening cut. The recorder is feature-complete
for the BEAM v1 surface area defined in milestones M0-M16. M17 adds the
release-readiness layer: CI matrix, OTP fixture coverage, stress
fixtures, packaging metadata, user documentation, and a release-check
gate.

### Added

- M0-M2: public scaffold, golden fixture contract, latest CTFS writer
  bridge, repository compliance harness.
- M3: standalone `record` CLI that drives a real BEAM target and
  produces a CTFS bundle.
- M4: minimal BEAM runtime session with `erlang:trace_delivered/1`
  shutdown barrier.
- M5: runtime function call/return/exception tracing through
  `erlang:trace/3`.
- M6: BEAM process and message tracing (`procs`, `set_on_spawn`,
  `send`, `receive`).
- M7: per-module recorder manifests under
  `recorder_metadata/manifests/`.
- M8: abstract-form-driven step instrumentation (process backend).
- M9: clause-entry variable bindings.
- M10: BEAM term value encoder.
- M11: standalone instrumented build CLI.
- M12: Mix integration via `mix codetracer.record` + Elixir source
  maps.
- M13: Rebar3 integration via the `rebar3_codetracer` plugin app.
- M14: cross-repo DAP flow integration.
- M15: UI + VS Code smoke parity (sibling-pinned to
  `codetracer-vscode-extension`).
- M16: optimized `erl_tracer`-style native backend (gen_server seam;
  see `:scope_deferred:` in the milestones plan for the deferred
  real-NIF follow-up).
- M17: CI matrix (Ubuntu Linux, OTP 26 + 27, Elixir 1.16 + 1.17), OTP
  fixture matrix (GenServer, Supervisor, Task, Agent, ETS, Application
  startup/shutdown), Phoenix/Plug-shaped smoke fixture, five stress
  fixtures (100k+ calls, many short-lived processes, large mailboxes,
  large terms, abrupt crashes), Hex/Mix/Rebar3/Cargo packaging
  metadata, user docs, and `just release-check`.

### Notes

- Phoenix/Plug fixture: the M17 recorder dev shell is offline so the
  smoke fixture uses a hand-rolled `:gen_tcp` HTTP/1.1 server shaped
  like `Plug.Router` instead of pulling the `:plug` Hex package. The
  recorder contract under test (`record` exits 0, the bundle is
  reader-loadable, the request handler call sequence is present) is
  the same contract a Phoenix `--no-html --no-ecto` app would
  exercise. Swapping the fixture for real Plug + Cowboy is mechanical.
- macOS CI matrix is documented but not currently run; the
  `nix-build` job is Linux-only because the Nix dev shell is a
  primary GitHub-hosted Linux runner. macOS coverage is open
  follow-up.
