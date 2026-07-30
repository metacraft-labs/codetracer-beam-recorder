set shell := ["bash", "-euo", "pipefail", "-c"]

build:
  if ! command -v cargo >/dev/null 2>&1; then nix develop --command just build; else just build-native; fi

build-native:
  cargo build --locked
  cd rebar3_codetracer && rebar3 compile

test:
  if ! command -v cargo >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 || ! command -v elixir >/dev/null 2>&1 || ! command -v mix >/dev/null 2>&1 || ! command -v erl >/dev/null 2>&1 || ! command -v erlc >/dev/null 2>&1 || ! command -v rebar3 >/dev/null 2>&1; then nix develop --command just test; else just test-rust && just test-goldens && just test-elixir && just test-erlang && just verify-trace-format-dependency && just test-integration && just verify-elixir-fixture-generation-no-silent-skip && just verify-beam-fixture-generation-no-silent-skip && just verify-runtime-session-test-no-silent-skip && just verify-function-trace-test-no-silent-skip && just verify-message-trace-test-no-silent-skip && just verify-manifest-source-location-test-no-silent-skip && just verify-step-instrumentation-test-no-silent-skip && just verify-native-tracer-parity-test-no-silent-skip && just verify-native-tracer-ordering-test-no-silent-skip && just verify-native-tracer-overflow-test-no-silent-skip && just verify-native-tracer-bench-test-no-silent-skip && just verify-otp-fixture-matrix-test-no-silent-skip && just verify-plug-smoke-test-no-silent-skip && just verify-plug-requests-test-no-silent-skip && just verify-phoenix-requests-test-no-silent-skip && just verify-stress-event-volume-test-no-silent-skip && just verify-release-check-no-silent-skip; fi

t: test

test-rust:
  cargo test --locked

test-elixir:
  bash tests/fixtures/run-elixir-canonical-flow.sh

test-erlang:
  bash tests/fixtures/run-erlang-canonical-flow.sh

test-goldens:
  bash tests/verify-golden-contract.sh

test-integration:
  cargo run --locked -- --help >/dev/null
  cargo run --locked -- --version | grep -F "$(grep -E '^version = "' Cargo.toml | head -n1 | cut -d '"' -f2)"
  trace_dir="$(mktemp -d "${TMPDIR:-/tmp}/codetracer-beam-recorder-cli.XXXXXX")"; set +e; cargo run --locked -- record --out-dir "$trace_dir" -- sh -c 'exit 7'; status="$?"; set -e; rm -rf "$trace_dir"; test "$status" -eq 7
  elixir tests/integration/ctfs_writer_bridge_test.exs
  cargo build --locked
  elixir tests/integration/runtime_session_test.exs
  elixir tests/integration/function_trace_test.exs
  elixir tests/integration/message_trace_test.exs
  elixir tests/integration/manifest_source_location_test.exs
  elixir tests/integration/step_instrumentation_test.exs
  elixir tests/integration/native_tracer_parity_test.exs
  elixir tests/integration/native_tracer_ordering_test.exs
  elixir tests/integration/native_tracer_overflow_test.exs
  elixir tests/integration/native_tracer_bench_test.exs
  elixir tests/integration/otp_fixture_matrix_test.exs
  elixir tests/integration/plug_smoke_test.exs
  just prepare-web-fixtures
  elixir tests/integration/plug_requests_test.exs
  elixir tests/integration/phoenix_requests_test.exs
  elixir tests/integration/stress_event_volume_test.exs

verify-trace-format-dependency:
  bash tests/verify-trace-format-dependency.sh

verify-elixir-fixture-generation-no-silent-skip:
  bash tests/verify-elixir-fixture-generation-no-silent-skip.sh

verify-beam-fixture-generation-no-silent-skip:
  bash tests/verify-beam-fixture-generation-no-silent-skip.sh

verify-runtime-session-test-no-silent-skip:
  bash tests/verify-runtime-session-test-no-silent-skip.sh

verify-function-trace-test-no-silent-skip:
  bash tests/verify-function-trace-test-no-silent-skip.sh

verify-message-trace-test-no-silent-skip:
  bash tests/verify-message-trace-test-no-silent-skip.sh

verify-manifest-source-location-test-no-silent-skip:
  bash tests/verify-manifest-source-location-test-no-silent-skip.sh

verify-step-instrumentation-test-no-silent-skip:
  bash tests/verify-step-instrumentation-test-no-silent-skip.sh

verify-native-tracer-parity-test-no-silent-skip:
  bash tests/verify-native-tracer-parity-test-no-silent-skip.sh

verify-native-tracer-ordering-test-no-silent-skip:
  bash tests/verify-native-tracer-ordering-test-no-silent-skip.sh

verify-native-tracer-overflow-test-no-silent-skip:
  bash tests/verify-native-tracer-overflow-test-no-silent-skip.sh

verify-native-tracer-bench-test-no-silent-skip:
  bash tests/verify-native-tracer-bench-test-no-silent-skip.sh

verify-otp-fixture-matrix-test-no-silent-skip:
  bash tests/verify-otp-fixture-matrix-test-no-silent-skip.sh

verify-plug-smoke-test-no-silent-skip:
  bash tests/verify-plug-smoke-test-no-silent-skip.sh

verify-plug-requests-test-no-silent-skip:
  bash tests/verify-plug-requests-test-no-silent-skip.sh

verify-phoenix-requests-test-no-silent-skip:
  bash tests/verify-phoenix-requests-test-no-silent-skip.sh

# RS-M8: fetch the real Plug/Cowboy and Phoenix packages the web demos are
# recorded against.  Separate from the suites so a Hex outage is reported as
# what it is instead of as a failing assertion.
prepare-web-fixtures:
  bash scripts/prepare-web-fixtures.sh

verify-stress-event-volume-test-no-silent-skip:
  bash tests/verify-stress-event-volume-test-no-silent-skip.sh

verify-release-check-no-silent-skip:
  bash tests/verify-release-check-no-silent-skip.sh

release-check:
  bash scripts/release-check.sh

# --- RS-M8: Request Panel demo + fixture ---

# Record a real Elixir web session and (unless CODETRACER_DEMO_RECORD_ONLY is
# set) open it in the GUI.  Invoked directly, or as the recording half of
# codetracer's `just demo-request-panel elixir`.
#
# FRAMEWORK is `plug` (Plug.Router on Cowboy) or `phoenix` (a real
# Phoenix.Endpoint, router and controllers).
demo-request-panel-elixir FRAMEWORK="plug":
  #!/usr/bin/env bash
  set -euo pipefail
  demo_dir="${CODETRACER_DEMO_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/codetracer/demos/request-panel-elixir}"
  echo "=== RS-M8 Request Panel demo — elixir/{{FRAMEWORK}} ==="
  case "{{FRAMEWORK}}" in
    plug) fixture=test-programs/elixir/plug_web; entry='PlugWeb.main()' ;;
    phoenix) fixture=test-programs/elixir/phoenix_web; entry='PhoenixWeb.main()' ;;
    *) echo "ERROR: unknown framework '{{FRAMEWORK}}' (plug|phoenix)" >&2; exit 1 ;;
  esac
  just build
  just prepare-web-fixtures
  (cd "$fixture" && MIX_ENV=test mix compile)
  rm -rf "$demo_dir"
  mkdir -p "$demo_dir"
  (cd "$fixture" && MIX_ENV=test "$(pwd)/../../../target/debug/codetracer-beam-recorder" \
      record --out-dir "$demo_dir" -- mix run --no-compile -e "$entry")
  # The spans are printed through the canonical Nim reader, so a failure to
  # record stays distinguishable from a failure to display.
  ./target/debug/codetracer-beam-recorder read-spans --bundle "$demo_dir"
  echo "[demo] recorded session in $demo_dir"
  if [ -n "${CODETRACER_DEMO_RECORD_ONLY:-}" ]; then
    exit 0
  fi
  if command -v ct >/dev/null 2>&1; then
    echo "[demo] launching the GUI; the REQUESTS panel docks itself once the"
    echo "[demo] first delta arrives (bottom edge strip if you close it)."
    exec ct replay -t "$demo_dir"
  fi
  echo "[demo] no 'ct' on PATH — open it by hand with:"
  echo "         ct replay -t $demo_dir"
  echo "[demo] (or run this through codetracer's recipe, which supplies ct:"
  echo "         direnv exec ../codetracer just demo-request-panel elixir)"

# Record the checked-in ViewModel-test fixture into OUT.
#
# OUT ends up holding the single `.ct` container under the name the codetracer
# test expects, so the fixture path is stable across machines.
record-request-panel-fixture OUT FRAMEWORK="plug":
  #!/usr/bin/env bash
  set -euo pipefail
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  CODETRACER_DEMO_DIR="$tmp" CODETRACER_DEMO_RECORD_ONLY=1 \
    just demo-request-panel-elixir {{FRAMEWORK}}
  rm -rf "{{OUT}}"
  mkdir -p "{{OUT}}"
  cp "$(ls "$tmp"/*.ct | head -n1)" "{{OUT}}/app.ct"
  echo "[fixture] wrote {{OUT}}/app.ct"

lint:
  if ! command -v cargo >/dev/null 2>&1 || ! command -v nixfmt >/dev/null 2>&1 || ! command -v shellcheck >/dev/null 2>&1; then nix develop --command just lint; else just lint-nix && just lint-rust && just lint-shell && just verify-repo-requirements && just verify-trace-format-dependency; fi

lint-nix:
  nixfmt --check flake.nix

lint-rust:
  cargo fmt --check
  cargo clippy --locked --all-targets -- -D warnings

lint-shell:
  shellcheck tests/verify-repo-requirements.sh tests/verify-golden-contract.sh tests/verify-trace-format-dependency.sh tests/verify-elixir-fixture-generation-no-silent-skip.sh tests/verify-beam-fixture-generation-no-silent-skip.sh tests/verify-runtime-session-test-no-silent-skip.sh tests/verify-function-trace-test-no-silent-skip.sh tests/verify-message-trace-test-no-silent-skip.sh tests/verify-manifest-source-location-test-no-silent-skip.sh tests/verify-step-instrumentation-test-no-silent-skip.sh tests/verify-native-tracer-parity-test-no-silent-skip.sh tests/verify-native-tracer-ordering-test-no-silent-skip.sh tests/verify-native-tracer-overflow-test-no-silent-skip.sh tests/verify-native-tracer-bench-test-no-silent-skip.sh tests/verify-otp-fixture-matrix-test-no-silent-skip.sh tests/verify-plug-smoke-test-no-silent-skip.sh tests/verify-plug-requests-test-no-silent-skip.sh tests/verify-phoenix-requests-test-no-silent-skip.sh tests/verify-stress-event-volume-test-no-silent-skip.sh tests/verify-release-check-no-silent-skip.sh tests/fixtures/*.sh scripts/*.sh

verify-repo-requirements:
  bash tests/verify-repo-requirements.sh

format:
  if ! command -v cargo >/dev/null 2>&1 || ! command -v nixfmt >/dev/null 2>&1 || ! command -v shfmt >/dev/null 2>&1; then nix develop --command just format; else just format-nix && just format-rust && just format-shell; fi

fmt: format

format-nix:
  nixfmt flake.nix

format-rust:
  cargo fmt

format-shell:
  shfmt -w tests/verify-repo-requirements.sh tests/verify-golden-contract.sh tests/verify-trace-format-dependency.sh tests/verify-elixir-fixture-generation-no-silent-skip.sh tests/verify-beam-fixture-generation-no-silent-skip.sh tests/verify-runtime-session-test-no-silent-skip.sh tests/verify-function-trace-test-no-silent-skip.sh tests/verify-message-trace-test-no-silent-skip.sh tests/verify-manifest-source-location-test-no-silent-skip.sh tests/verify-step-instrumentation-test-no-silent-skip.sh tests/verify-native-tracer-parity-test-no-silent-skip.sh tests/verify-native-tracer-ordering-test-no-silent-skip.sh tests/verify-native-tracer-overflow-test-no-silent-skip.sh tests/verify-native-tracer-bench-test-no-silent-skip.sh tests/verify-otp-fixture-matrix-test-no-silent-skip.sh tests/verify-plug-smoke-test-no-silent-skip.sh tests/verify-plug-requests-test-no-silent-skip.sh tests/verify-phoenix-requests-test-no-silent-skip.sh tests/verify-stress-event-volume-test-no-silent-skip.sh tests/verify-release-check-no-silent-skip.sh tests/fixtures/*.sh scripts/*.sh

test-integration-fixture:
  just test-integration

bench:
  cargo build --release --locked
  target/release/codetracer-beam-recorder --version >/dev/null

bump-version new_version:
  #!/usr/bin/env python3
  import pathlib, re, subprocess
  raw = "{{new_version}}"
  cargo = pathlib.Path("Cargo.toml")
  cur_match = re.search(r'^version\s*=\s*"(\d+\.\d+\.\d+)"', cargo.read_text(), re.MULTILINE)
  cur = cur_match.group(1) if cur_match else "0.1.0"
  if re.match(r'^\d+\.\d+\.\d+$', raw):
      new = raw
  else:
      a, b, p = map(int, cur.split("."))
      if raw == "major": new = f"{a+1}.0.0"
      elif raw == "minor": new = f"{a}.{b+1}.0"
      elif raw == "patch": new = f"{a}.{b}.{p+1}"
      else: raise SystemExit(f"unknown bump component: {raw!r}")
  text = cargo.read_text()
  text = re.sub(r'(^version\s*=\s*")\d+\.\d+\.\d+(")', rf'\g<1>{new}\g<2>', text, count=1, flags=re.MULTILINE)
  cargo.write_text(text)
  print(f"Cargo.toml: {cur} -> {new}")
  # Refresh Cargo.lock; allow failure for offline runs.
  try:
      subprocess.run(["cargo", "update", "--workspace"], check=False)
  except FileNotFoundError:
      print("(cargo not on PATH; skipping cargo update)")

# --- M13: Packaging UX Standardization ---
# Implements Repo-Requirements.md §2.8 packaging UX for the BEAM
# language-ecosystem recorder. Single channel: hex.

# Build a release artifact for the given channel.
# Supported channels: hex
build-package channel:
  #!/usr/bin/env bash
  set -euo pipefail
  case "{{channel}}" in
      hex)
          just build
          if command -v mix >/dev/null 2>&1 && [ -f rebar3_codetracer/mix.exs ]; then
              cd rebar3_codetracer && mix hex.build || true
          else
              echo "[build-package hex] mix or rebar3_codetracer/mix.exs missing; nothing to archive yet."
          fi
          ;;
      *)
          echo "::error::unknown channel '{{channel}}'. BEAM recorder only supports 'hex'." >&2
          exit 1
          ;;
  esac

# Verify the artifact produced by `build-package <channel>`.
verify-package channel:
  #!/usr/bin/env python3
  import os, shutil, subprocess, sys
  from pathlib import Path
  ch = "{{channel}}"
  strict = os.environ.get("CT_VERIFY_STRICT") == "1"
  if ch != "hex":
      print(f"::error::unknown channel {ch!r}; BEAM recorder only supports 'hex'")
      sys.exit(1)
  rebar = Path("rebar3_codetracer")
  if not rebar.exists():
      print("[verify] rebar3_codetracer/ not present; nothing to verify")
      sys.exit(0)
  if shutil.which("mix"):
      subprocess.run(["mix", "hex.build", "--unpack"], cwd=rebar, check=False)
      print("[verify] hex build OK")
  else:
      if strict:
          print("::error::mix required in strict mode"); sys.exit(1)
      print("[verify] SKIP: mix not on PATH")

# Per-channel shortcut.
build-hex:
  just build-package hex

verify-hex:
  just verify-package hex
