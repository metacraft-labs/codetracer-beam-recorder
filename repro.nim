## Reprobuild dev env + build recipe for codetracer-beam-recorder.
##
## Mirrors the dev shell declared in ``flake.nix`` (Linux/macOS).
## ``repro build`` / ``repro test`` reproduce the same recorder artefact
## and the cargo-test + golden-contract portion of the test set that
## ``just build`` / ``just test`` produce today.
##
## Per ``codetracer-specs/Repo-Requirements.md`` §2.8 the recipe
## expresses build and test execution NATIVELY through typed-tool
## edges (`cargo.build`, `cargo.test`). It does NOT delegate to
## `shell(command = "bash scripts/...")` wrappers for the Rust build /
## test — delegation defeats the engine's incremental-build,
## action-cache, per-test invalidation, and the CI sharding the engine
## grows into per ``reprobuild-specs/CI-Sharding.md``. The ONE
## ``sh.shell`` edge below wraps the repo's golden-contract verification
## script, which is not a cargo target — it is a POSIX-shell assertion
## harness (``jq`` over the checked-in canonical-flow fixtures) that
## ``just test`` runs as ``test-goldens`` alongside ``cargo test`` (see
## ``Justfile`` ``test:``), so it is modelled as its own execute edge
## rather than dropped.
##
## On Linux/macOS the Nix flake supplies the toolchain. The build outputs
## and the modelled test pass/fail set match ``just`` — CI cross-checks
## this through the side-by-side `ci.yml` (nix) + `ci-reprobuild.yml`
## (reprobuild) flow per Repo-Requirements §2.9.
##
## **This repo is a Rust CONSUMER of six sibling crates, but NOT a
## reprobuild ``uses: "<sibling>"`` consumer.** The recorder's
## ``Cargo.toml`` pulls in six crates from the sibling
## ``codetracer-trace-format`` repo via cargo ``path`` dependencies
## (``codetracer_ctfs``, ``codetracer_trace_format_cbor_zstd``,
## ``codetracer_trace_reader``, ``codetracer_trace_types``,
## ``codetracer_trace_writer``, ``codetracer_trace_writer_nim``). All are
## resolved and compiled INSIDE cargo — out of reprobuild's reach — so
## they are NOT reprobuild library-threaded ``uses:`` consumptions (the
## SC-11 develop-mode src-threading applies only to reprobuild's own
## ``nim.c`` edges, and ``codetracer-trace-format`` is a Rust workspace,
## not a Nim-library sibling in the AVAILABLE set). This matches how the
## sibling recorders (evm, fuel, circom, cairo, …) model the identical
## dependency: the toolchain floor for the Nim FFI that
## ``codetracer_trace_writer_nim``'s ``build.rs`` compiles at cargo build
## time (``nim`` + ``nimble`` + ``capnp`` + ``zstd``) is declared in
## ``uses:``, and cargo does the cross-crate wiring itself. The lock
## below is therefore self-only.
##
## **BEAM/OTP integration test set (modelled).** ``just test``
## additionally runs the Elixir, Erlang, and rebar3 integration suites
## (``test-elixir``, ``test-erlang``, ``test-integration`` and the
## ``verify-*-no-silent-skip.sh`` gates). Those spin up a live BEAM VM
## and drive ``elixir`` / ``mix`` / ``erl`` / ``erlc`` / ``rebar3``
## against real OTP applications. The nix dev shell (``flake.nix``)
## already provisions the whole BEAM toolchain — ``erlang`` (``erl`` /
## ``erlc``), ``elixir`` (``mix``), and ``rebar3`` — on ``PATH``, exactly
## as ``just test`` consumes them, so these suites need no additional
## reprobuild toolchain package. They are therefore modelled below as
## ``sh.shell`` execute edges enrolled into the ``test`` collection,
## mirroring how the cairo / leo recorders model their non-cargo
## verification steps: the canonical-flow fixtures
## (``test-elixir`` / ``test-erlang``), the CLI smoke check, the thirteen
## live-BEAM Elixir integration suites, and the fifteen
## ``verify-*-no-silent-skip.sh`` structural gates. The integration edges
## drive the DEBUG recorder binary (see ``recorderDebugBuild`` below) to
## match the canonical ``just test-integration`` path, which builds the
## debug profile and whose step-granularity assertions differ under
## release optimisation.
##
## **Serial pool for the heavy live-BEAM edges (FUP-E3).** The thirteen
## live-BEAM integration suites plus the two canonical-flow fixtures each
## spin up a live BEAM VM. Run at the engine's default 8-way parallelism —
## competing with cold cargo builds and with one another — they blow past
## ExUnit's per-test timeout and make a cold ``repro build test``
## fail nondeterministically with ``ExUnit.TimeoutError`` (the failing set
## drifts run to run). Two mutually-reinforcing measures make cold runs
## deterministic. (1) They are routed through the capacity-1 build pool
## ``codetracer-beam-recorder.live-beam-serial`` (declared with
## ``buildPool`` in the ``build:`` block and forwarded via the
## ``pooledShell`` wrapper's ``pool`` slot) — a pure SCHEDULING fix
## mirroring FUP-E1's ``isonim.design-review-serial`` and the canonical
## ``nim_pty.pty-serial`` pool that removes cross-edge CPU contention. But
## the pool alone is necessary-not-sufficient: the real tip-over is
## MONITOR-SHIM OVERHEAD, not contention — the io-mon LD_PRELOAD shim adds
## ~5x wall-clock to these recorder-heavy suites (``native_tracer_parity``
## runs ~11s unmonitored but ~60s under the shim), so even an edge running
## essentially alone can exceed the default 60000ms per-test budget. So
## (2) the thirteen MONITORED integration edges are additionally given a
## generous 300000ms (5 min) per-test ExUnit timeout, set purely on the
## edge command via ``elixir -e`` (see the loop below) — the ``.exs`` test
## files stay BYTE-IDENTICAL and the unmonitored ``just test`` path keeps
## ExUnit's 60000ms default (it does not use this recipe). No test is
## skipped, relaxed, or removed; a broken assertion still fails FAST. The
## cheap edges — the fifteen
## ``verify-*-no-silent-skip.sh`` gates, the CLI smoke edge, and the cargo
## build/test edges — stay UNPOOLED and parallel.
##
## All thirteen live-BEAM integration suites are enrolled, including
## ``tests/integration/function_trace_test.exs`` (re-included in FUP-L).
## Two of its subtests assert ``call_function_ids`` ordering; they now
## assert the spec-correct CALL-ENTRY order ``[main, compute]`` that the
## recorder emits — a call record's ``call_key`` is assigned at call entry
## (``codetracer_trace_writer/call_stream.rs`` ``CallStreamBuilder.observe``
## pushes the record with ``call_key = records.len()`` on the ``Call``
## event; the matching ``Return`` only finalizes the record's contents in
## place, and ``finish()`` returns records in ``call_key`` order). The
## earlier "completion order" expectation was a stale (CMP-M4-era) test
## bug, corrected in FUP-L; the recorder was NOT touched. Its structural
## ``verify-function-trace-test-no-silent-skip`` gate stays enrolled too.
##
## **Tool provisioning.** ``defaultToolProvisioning "path"`` matches the
## canonical Rust-recorder recipes: the nix dev shell puts ``cargo`` /
## ``rustc`` / ``nim`` / ``nimble`` / ``capnp`` / ``jq`` / ``erlang`` /
## ``elixir`` / ``rebar3`` / ``zstd`` on ``PATH`` (and
## ``PKG_CONFIG_PATH`` for libzstd), so the weak-local PATH resolver is
## the right default. Without it ``repro build`` refuses to run with
## "typed tool provisioning is required for uses declarations".

import repro_project_dsl
import repro_dsl_stdlib/packages/sh

## ``sh.shell`` (repro_dsl_stdlib/packages/sh.nim) intentionally does NOT
## expose the engine's named-pool slot. The heavy live-BEAM integration
## edges below must be serialised (see the "serial pool" note in the
## package docstring), so this thin wrapper reconstructs the exact same
## ``sh -c`` typed-tool call ``sh.shell`` builds and forwards it through a
## named build pool via ``recordToolInvocation`` — the reprobuild-native
## scheduling knob (BuildAction.pool → the engine's ``poolRunning``
## capacity tracker). It is byte-for-byte the ``sh.shell`` call shape plus
## the ``pool`` / ``poolUnits`` fields; every non-heavy edge keeps using
## plain ``shell``. Mirrors FUP-E1 (``isonim.design-review-serial``) and
## the canonical ``nim_pty.pty-serial`` pool: NOTHING in any test is
## skipped, relaxed, or removed — only the scheduling is constrained.
proc pooledShell(command, pool: string; actionId = "";
                 after: openArray[BuildActionDef] = [];
                 extraInputs: openArray[string] = [];
                 poolUnits: uint32 = 1'u32;
                 cacheable = true): BuildActionDef {.discardable.} =
  let call = publicCliCall("sh", "sh", "", "sh.sh.call", @[
    cliArg("command", command, cpkFlag, 0, "-c"),
    cliArgSeq("args", @[], cpkPositional, 0)
  ])
  let selectedActionId =
    if actionId.len > 0: actionId else: defaultToolActionId(call)
  recordToolInvocation(selectedActionId, call,
    deps = combineActionDeps(@[], after),
    extraInputs = extraInputs,
    pool = pool,
    poolUnits = poolUnits,
    cacheable = cacheable,
    dependencyPolicy = automaticMonitorPolicy())

package codetracer_beam_recorder:
  defaultToolProvisioning "path"

  uses:
    # Rust toolchain — declared by version so the tarball-direct
    # provisioning entries in repro_dsl_stdlib/packages/cargo.nim /
    # rustc.nim resolve. On Linux/macOS the nix flake supplies the same
    # versions.
    "rustc >=1.85"
    "cargo >=1.85"

    # Nim toolchain — the sibling ``codetracer_trace_writer_nim`` crate's
    # build.rs compiles a Nim FFI static library at cargo build time via
    # ``nim c``; ``nimble`` resolves that FFI's nimble requirements.
    "nim >=2.2 <3.0"
    "nimble"

    # Cap'n Proto schema compiler used by the trace-format crates'
    # build.rs (``capnpc`` over the trace schema).
    "capnp"

    # pkg-config + libzstd headers + library, needed when linking the Nim
    # FFI static library into the cargo build (the FFI's C output
    # ``#include``s ``zstd.h`` and the CBOR+Zstd writer links libzstd).
    "pkg-config"
    "zstd"

    # POSIX shell — drives the golden-contract verification edge below,
    # the same ``bash tests/verify-golden-contract.sh`` step ``just test``
    # runs (as ``test-goldens``) alongside ``cargo test``.
    "sh"

    # NB: the BEAM/OTP runtime (``erl`` / ``erlc`` / ``elixir`` / ``mix``
    # / ``rebar3``) and ``jq`` are NOT declared here. Reprobuild resolves
    # a ``uses:`` selector to a PATH binary of the SAME name; the OTP
    # tools ship binaries named ``erl`` / ``elixir`` / … (there is no
    # ``erlang`` binary), and reprobuild has no BEAM tool-edge to drive
    # them through, so declaring them would only add a failing PATH probe.
    # These tools are runtime dependencies of the spawned cargo test
    # process (``tests/cli_test.rs`` ``e2e_*`` compile+record real Erlang
    # and Elixir programs), of the golden-contract shell script, and of
    # the BEAM/OTP integration ``sh.shell`` edges below (the
    # canonical-flow fixtures and the thirteen live-BEAM Elixir suites drive
    # ``mix`` / ``elixir`` / ``erl`` / ``erlc`` / ``rebar3`` as child
    # processes); they are supplied to those child processes by the same
    # nix dev shell PATH the flake provides — exactly as ``just test``
    # runs them today.

  executable codetracerBeamRecorder:
    name: "codetracer-beam-recorder"

  devEnv:
    activity "default"

  build:
    # ---- Primary build edge (the `default` collection) ----------------
    #
    # Native cargo build for the recorder binary. Enrolled into the
    # conventional ``default`` collection per
    # reprobuild-specs/Build-Graph-Collections.md §"`default`"; this
    # makes ``repro build`` (no positional target) materialise this
    # edge's closure.
    #
    # ``locked = true`` because this repo DOES check in ``Cargo.lock``
    # (the committed lock is the version source of truth per AGENTS.md;
    # it pins the six sibling trace-format crates). The recorder has no
    # ``build.rs`` of its own; the only inputs are the manifest, the lock
    # and the ``src`` tree. The sibling trace-format crates cargo pulls in
    # via ``path`` deps are tracked per-crate at action-end by cargo's own
    # ``.d`` depfiles under ``target/*/deps``.
    const binarySuffix = (when defined(windows): ".exe" else: "")
    const recorderBinary =
      "target/release/codetracer-beam-recorder" & binarySuffix

    let recorderBuild = cargo.build(
      locked = true,
      release = true,
      actionId = "codetracer-beam-recorder.cargo-build",
      extraInputs = @[
        "Cargo.toml", "Cargo.lock",
        "src"
      ],
      extraOutputs = @[recorderBinary])
    discard collect("default", @[recorderBuild])

    # ---- Test-binary build + run edges (the `test` collection) -------
    #
    # Two-stage shape per Repo-Requirements.md §2.8: `cargo.test(noRun =
    # true)` builds every cargo test binary into
    # `target/debug/deps/<crate>-<hash>` (the engine tracks the deps
    # directory as the build edge's effect set because the hashed
    # filename floats with input content); `cargo.test(noRun = false)`
    # then runs the binaries in one cargo invocation. The execute edge
    # depends on the build edge so the engine only re-runs tests when an
    # input changed since the last successful execution.
    #
    # Per-test execute edges fall out automatically once the
    # ct-test-runner cargo adapter lands per
    # reprobuild-specs/Test-Edges-And-Parallel-Runner.milestones.org
    # §M4 — the whole-binary edge becomes a fan-out point without
    # changing this recipe.
    #
    # ``tests/cli_test.rs`` drives the recorder against real Erlang and
    # Elixir sources under ``test-programs``, so those fixtures are inputs
    # to both the build and the run.

    let testsBuild = cargo.test(
      locked = true,
      noRun = true,
      actionId = "codetracer-beam-recorder.cargo-test-build",
      extraInputs = @[
        "Cargo.toml", "Cargo.lock",
        "src", "tests", "test-programs"
      ],
      extraOutputs = @["target/debug/deps"])

    let testsRun = cargo.test(
      locked = true,
      actionId = "codetracer-beam-recorder.cargo-test-run",
      after = @[testsBuild.action],
      extraInputs = @[
        "Cargo.toml", "Cargo.lock",
        "src", "tests", "test-programs",
        "target/debug/deps"
      ])

    # ---- Golden-contract verification edge ----------------------------
    #
    # ``just test`` runs ``bash tests/verify-golden-contract.sh`` (as
    # ``test-goldens``) alongside ``cargo test``. The script asserts the
    # canonical-flow golden oracle (``tests/goldens/canonical_flow``) stays
    # documented and source-backed, using only ``jq`` over the checked-in
    # fixtures and Erlang/Elixir source files (no live BEAM VM). It is not
    # a cargo target, so it is modelled as its own ``sh.shell`` execute
    # edge rather than dropped — reproducing this host-portable slice of
    # the repo's ``just test`` set.
    let goldenVerify = shell(
      command = "bash tests/verify-golden-contract.sh",
      actionId = "codetracer-beam-recorder.verify-golden-contract",
      extraInputs = @[
        "tests/verify-golden-contract.sh",
        "tests/goldens",
        "test-programs"
      ],
      cacheable = false)

    # ---- BEAM/OTP integration edges (the `test` collection) ----------
    #
    # These re-include the deferred BEAM/OTP portion of ``just test``:
    # ``test-elixir`` / ``test-erlang`` (canonical-flow fixtures), the
    # CLI smoke check, the thirteen live-BEAM Elixir integration suites, and
    # the fifteen ``verify-*-no-silent-skip.sh`` structural gates. Each is
    # a native ``sh.shell`` edge under the engine's automatic monitor, so
    # the real ``elixir`` / ``mix`` / ``erl`` / ``erlc`` / ``rebar3``
    # subprocesses (inherited from the nix dev-shell PATH) are observed —
    # mirroring how the cairo / leo recorders model non-cargo verification
    # steps.

    # Debug recorder build for the integration edges: ``just
    # test-integration`` builds the DEBUG profile (``cargo build
    # --locked``) and the Elixir harnesses resolve
    # ``target/debug/codetracer-beam-recorder`` first. Two suites
    # (``step_instrumentation``, ``native_tracer_parity``) assert on step
    # granularity that differs under release optimisation, so the edges
    # MUST drive the debug binary to match the canonical ``just`` path.
    const recorderDebugBinary =
      "target/debug/codetracer-beam-recorder" & binarySuffix
    let recorderDebugBuild = cargo.build(
      locked = true,
      release = false,
      actionId = "codetracer-beam-recorder.cargo-build-debug",
      extraInputs = @[
        "Cargo.toml", "Cargo.lock",
        "src"
      ],
      extraOutputs = @[recorderDebugBinary])

    # Capacity-1 serial pool for the HEAVY live-BEAM edges. Under the
    # engine's 8-way parallel scheduler these edges (each spins up a live
    # BEAM VM and drives ``mix`` / ``elixir`` / ``erl`` / ``erlc`` /
    # ``rebar3`` against real OTP apps) contend for CPU with cold cargo
    # builds and with each other, blowing past ExUnit's per-test
    # timeout and making a cold ``repro build test`` fail nondeterministically
    # with ``ExUnit.TimeoutError``. Routing them through a capacity-1 pool
    # sequences them so each runs with headroom — a pure SCHEDULING fix
    # (BuildAction.pool → the engine's ``poolRunning`` capacity tracker).
    # This removes cross-edge CPU contention but is necessary-not-sufficient
    # on its own (the dominant tip-over is monitor-shim overhead — see the
    # ExUnit-timeout note by the integration loop below, which raises the
    # MONITORED edges' per-test budget to 5 min). NOTHING is skipped,
    # relaxed, or removed. Mirrors FUP-E1
    # (``isonim.design-review-serial``) and ``nim_pty.pty-serial``. The
    # cheap gates (the fifteen ``verify-*-no-silent-skip.sh`` structural
    # checks), the CLI smoke edge, and the cargo build/test edges stay
    # UNPOOLED and parallel — only the heavy live-BEAM edges are enrolled.
    const beamSerialPool = "codetracer-beam-recorder.live-beam-serial"
    discard buildPool(beamSerialPool, 1'u32)

    # ``test-elixir`` / ``test-erlang``: compile + run the canonical-flow
    # fixtures via ``mix`` and ``erlc`` / ``erl``, asserting stdout ``94``.
    # Heavy live-BEAM edges → routed through the capacity-1 serial pool.
    let elixirCanonicalFlow = pooledShell(
      command = "bash tests/fixtures/run-elixir-canonical-flow.sh",
      pool = beamSerialPool,
      actionId = "codetracer-beam-recorder.test-elixir-canonical-flow",
      extraInputs = @[
        "tests/fixtures/run-elixir-canonical-flow.sh",
        "test-programs/elixir/canonical_flow"],
      cacheable = false)

    let erlangCanonicalFlow = pooledShell(
      command = "bash tests/fixtures/run-erlang-canonical-flow.sh",
      pool = beamSerialPool,
      actionId = "codetracer-beam-recorder.test-erlang-canonical-flow",
      extraInputs = @[
        "tests/fixtures/run-erlang-canonical-flow.sh",
        "test-programs/erlang/canonical_flow"],
      cacheable = false)

    # CLI smoke: ``--help`` / ``--version`` (matched against Cargo.toml)
    # and a ``record`` run whose child exits 7, asserting exit-code
    # passthrough — the host-portable head of ``just test-integration``.
    let cliSmoke = shell(
      command =
        "set -euo pipefail; " &
        "bin=\"$PWD/" & recorderDebugBinary & "\"; " &
        "\"$bin\" --help >/dev/null; " &
        "want=$(grep -E '^version = \"' Cargo.toml | head -n1 | cut -d '\"' -f2); " &
        "\"$bin\" --version | grep -F \"$want\"; " &
        "d=$(mktemp -d \"${TMPDIR:-/tmp}/ctbr-cli.XXXXXX\"); " &
        "set +e; \"$bin\" record --out-dir \"$d\" -- sh -c 'exit 7'; s=$?; set -e; " &
        "rm -rf \"$d\"; test \"$s\" -eq 7",
      actionId = "codetracer-beam-recorder.cli-smoke",
      after = @[recorderDebugBuild],
      extraInputs = @[recorderDebugBinary, "Cargo.toml"],
      cacheable = false)

    var beamEdges: seq[BuildActionDef] =
      @[elixirCanonicalFlow, erlangCanonicalFlow, cliSmoke]

    # The fifteen live-BEAM Elixir integration suites. Each drives the
    # recorder against a real BEAM VM and asserts on the produced CTFS
    # trace. ``function_trace_test`` is enrolled here (re-included in FUP-L
    # after its stale "completion order" call-ordering assertions were
    # corrected to the spec-correct call-entry order the recorder emits;
    # the recorder was not touched — see the docstring).
    const beamIntegrationTests = [
      "ctfs_writer_bridge_test",
      "runtime_session_test",
      "function_trace_test",
      "message_trace_test",
      "manifest_source_location_test",
      "step_instrumentation_test",
      "native_tracer_parity_test",
      "native_tracer_ordering_test",
      "native_tracer_overflow_test",
      "native_tracer_bench_test",
      "otp_fixture_matrix_test",
      "plug_smoke_test",
      # RS-M8 web-request spans. These two need the real plug_cowboy /
      # phoenix packages under each demo's ``deps/``; the fetch is
      # ``scripts/prepare-web-fixtures.sh`` (``just prepare-web-fixtures``)
      # and the suites fail loudly rather than skipping when it has not
      # been run, so an unfetched tree can never look like coverage.
      "plug_requests_test",
      "phoenix_requests_test",
      "stress_event_volume_test"
    ]
    # Per-test ExUnit timeout (ms) applied to the MONITORED integration
    # edges only. The reprobuild automatic monitor LD_PRELOADs the io-mon
    # shim into ``elixir`` and every ``System.cmd`` recorder child, adding
    # ~5x wall-clock to these recorder-heavy suites: e.g.
    # ``native_tracer_parity_test`` runs ~11s UNMONITORED but ~60s UNDER
    # THE SHIM, tipping past ExUnit's default 60000ms per-test budget and
    # dying with ``ExUnit.TimeoutError`` nondeterministically on a cold
    # ``repro build test``. The tests are CORRECT (0 assertion failures) —
    # they are just killed prematurely by a too-tight timeout under the
    # EXPECTED monitor overhead, so the serial pool above (which removes
    # cross-edge CPU contention) is necessary but not sufficient. We give
    # the monitored edges a generous 5-minute budget so the shim's
    # overhead cannot prematurely kill a correct, slow-under-monitor test.
    # This is NOT a weakening: a broken assertion still fails FAST (a
    # failed assert never runs the clock out), and only the reprobuild
    # edge is affected — the unmonitored ``just test`` path runs the same
    # ``.exs`` files with ExUnit's built-in 60000ms default UNCHANGED (it
    # does not go through this recipe). It is set purely on the EDGE
    # COMMAND via ``elixir -e`` (the ``.exs`` files stay byte-identical):
    # the ``:ex_unit`` app is loaded first so its later ``ExUnit.start()``
    # app-load cannot clobber the value, then ``:timeout`` is put into the
    # app env BEFORE the required test file's ``ExUnit.start()`` reads it.
    # The underlying shim slowness is tracked as a separate follow-up.
    const monitoredExUnitTimeoutMs = 300_000
    const exUnitTimeoutPrelude =
      "elixir -e 'Application.load(:ex_unit); " &
      "Application.put_env(:ex_unit, :timeout, " &
      $monitoredExUnitTimeoutMs & ")' -r "

    for t in beamIntegrationTests:
      # Heavy live-BEAM edges → routed through the capacity-1 serial pool so
      # they do not race ExUnit's timeout under contention, AND given a
      # raised (5 min) per-test ExUnit timeout so the ~5x monitor-shim
      # overhead cannot prematurely kill a correct, slow-under-monitor test.
      # RS-M8: the two web-span suites are recorded against real Hex
      # packages, so their edge fetches them first. Every other suite runs
      # entirely offline and must keep doing so.
      let prepare =
        if t in ["plug_requests_test", "phoenix_requests_test"]:
          "bash scripts/prepare-web-fixtures.sh && "
        else:
          ""
      beamEdges.add pooledShell(
        command =
          prepare &
          "CODETRACER_BEAM_RECORDER_BIN=\"$PWD/" & recorderDebugBinary &
          "\" " & exUnitTimeoutPrelude & "tests/integration/" & t & ".exs",
        pool = beamSerialPool,
        actionId = "codetracer-beam-recorder.integration-" & t,
        after = @[recorderDebugBuild],
        extraInputs = @[
          "tests/integration/" & t & ".exs",
          "tests/integration/support", "scripts",
          "lib", "test-programs", "mix.exs", "rebar3_codetracer",
          recorderDebugBinary],
        cacheable = false)

    # The seventeen ``verify-*-no-silent-skip.sh`` structural gates: pure
    # ``sh`` + ``grep`` assertions that the integration test files and
    # their Justfile wiring have not been gutted into no-ops. Cheap and
    # deterministic, so left cacheable (the default).
    const beamNoSilentSkipGates = [
      "elixir-fixture-generation",
      "beam-fixture-generation",
      "runtime-session-test",
      "function-trace-test",
      "message-trace-test",
      "manifest-source-location-test",
      "step-instrumentation-test",
      "native-tracer-parity-test",
      "native-tracer-ordering-test",
      "native-tracer-overflow-test",
      "native-tracer-bench-test",
      "otp-fixture-matrix-test",
      "plug-smoke-test",
      "plug-requests-test",
      "phoenix-requests-test",
      "stress-event-volume-test",
      "release-check"
    ]
    for g in beamNoSilentSkipGates:
      beamEdges.add shell(
        command = "bash tests/verify-" & g & "-no-silent-skip.sh",
        actionId = "codetracer-beam-recorder.verify-" & g & "-no-silent-skip",
        extraInputs = @[
          "tests/verify-" & g & "-no-silent-skip.sh",
          "tests/integration", "tests/fixtures", "scripts",
          "test-programs", "repro.nim", "Justfile"])

    discard collect("test", @[testsRun.action, goldenVerify] & beamEdges)
