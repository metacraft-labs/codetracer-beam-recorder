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
## **Deferred BEAM/OTP integration test set.** ``just test`` additionally
## runs the Elixir, Erlang, and rebar3 integration suites
## (``test-elixir``, ``test-erlang``, ``test-integration`` and the
## ``verify-*-no-silent-skip.sh`` gates). Those spin up a live BEAM VM
## and drive ``elixir`` / ``mix`` / ``erl`` / ``erlc`` / ``rebar3``
## against real OTP applications. They are NOT modelled by this recipe:
## they need a provisioned BEAM/OTP + Elixir + rebar3 runtime that the
## reprobuild toolchain set does not yet package, so modelling them would
## be a silent env-blocked skip. The recipe covers the two host-portable,
## deterministic portions of ``just test`` — the whole ``cargo test``
## binary (which itself exercises the recorder end to end against the
## real BEAM tracer through the ``e2e_*`` integration tests, driven by the
## nix-flake BEAM toolchain) and the ``jq``-only golden-contract
## assertion. The BEAM/OTP-runtime suites remain gated to ``just test`` /
## ``ci.yml`` until a BEAM reprobuild package lands.
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
    # and Elixir programs) and of the golden-contract shell script; they
    # are supplied to those child processes by the same nix dev shell PATH
    # the flake provides — exactly as ``just test`` runs them today.

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

    discard collect("test", @[testsRun.action, goldenVerify])
