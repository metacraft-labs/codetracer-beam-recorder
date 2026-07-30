#!/usr/bin/env bash
set -euo pipefail

# RS-M8 verification guard for tests/integration/plug_requests_test.exs.
#
# The suite is only worth anything if it drives a REAL Plug/Cowboy server and
# asserts the container's own span stream, so this gate pins exactly that: the
# demo exists and depends on plug_cowboy, the middleware is installed, the test
# reads spans through the recorder's `read-spans` (i.e. the canonical Nim
# decoder), and the falsifiability control -- the second, strictly sequential
# recording -- is still there.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_file="$repo_root/tests/integration/plug_requests_test.exs"
helpers="$repo_root/tests/integration/support/span_stream_helpers.exs"
fixture_dir="$repo_root/test-programs/elixir/plug_web"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -f "$test_file" ]] ||
  fail "tests/integration/plug_requests_test.exs is missing; RS-M8 requires it"

[[ -f "$helpers" ]] ||
  fail "tests/integration/support/span_stream_helpers.exs is missing"

# Everything below greps the EXECUTABLE BODY, not the whole file: the suite's
# `@moduledoc` names every claim this gate pins, so grepping the raw file would
# let someone delete the assertions and keep the gate green on the prose alone.
test_body="$(awk '/^  @moduledoc """/ {skip = 1; next} skip && /^  """$/ {skip = 0; next} !skip' "$test_file")"

for required in \
  "$fixture_dir/mix.exs" \
  "$fixture_dir/mix.lock" \
  "$fixture_dir/lib/plug_web.ex" \
  "$fixture_dir/lib/plug_web/router.ex" \
  "$fixture_dir/lib/plug_web/endpoint.ex" \
  "$fixture_dir/lib/plug_web/barrier.ex"; do
  [[ -f "$required" ]] || fail "$required missing"
done

grep -Fq ':plug_cowboy' "$fixture_dir/mix.exs" ||
  fail "the plug_web demo must depend on the real plug_cowboy package"

grep -Fq 'CodetracerBeamRecorder.Plug' "$fixture_dir/lib/plug_web/endpoint.ex" ||
  fail "the plug_web demo must install the recorder's Plug middleware"

grep -Fq 'plug_requests_land_in_span_stream' <<<"$test_body" ||
  fail "$test_file must contain test \"plug_requests_land_in_span_stream\""

grep -Fq 'recorder_binary!' "$helpers" ||
  fail "the span helpers must invoke the real recorder binary — no mock recorder"

grep -Fq 'read-spans' "$helpers" ||
  fail "spans must be read back through the recorder's read-spans subcommand"

grep -Fq 'beam.pid' <<<"$test_body" ||
  fail "plug_requests_test must assert the owning BEAM process id is in span metadata"

grep -Fq 'concurrent_with_siblings' <<<"$test_body" ||
  fail "plug_requests_test must assert the concurrency structural bit"

grep -Fq 'CT_PLUG_WEB_SEQUENTIAL' <<<"$test_body" ||
  fail "plug_requests_test must keep the sequential-schedule control recording; without it the concurrency assertion is unfalsifiable"

grep -Fq 'contiguous_on_one_thread' <<<"$test_body" ||
  fail "plug_requests_test must assert the contiguity structural bit"

[[ "$(grep -c 'H.record!(' <<<"$test_body")" -ge 2 ]] ||
  fail "plug_requests_test must record the demo TWICE -- the rendezvous schedule and the strictly sequential control -- or the concurrency assertion is unfalsifiable"

grep -Fq 'sequential_spans' <<<"$test_body" ||
  fail "the control recording's spans must be ASSERTED, not merely recorded"

# Refuse silent-skip patterns.
if grep -E '@tag[[:space:]]+:?skip' "$test_file" >/dev/null; then
  fail "plug_requests_test must not be tagged :skip"
fi

if grep -E 'System\.get_env\("[^"]+"\)[^,]*\|\|[[:space:]]*ExUnit' "$test_file" >/dev/null; then
  fail "plug_requests_test must not bail out via env var"
fi

if grep -Eq 'File\.dir\?.*deps.*(->|do)[[:space:]]*$' "$helpers" &&
  ! grep -Fq 'assert File.dir?(Path.join(fixture_dir, "deps"))' "$helpers"; then
  fail "a missing deps/ must be a hard failure, not a skip"
fi

if ! grep -F 'tests/integration/plug_requests_test.exs' "$repo_root/Justfile" >/dev/null; then
  fail "Justfile must run tests/integration/plug_requests_test.exs as part of \`just test-integration\`"
fi

if ! grep -F 'plug_requests' "$repo_root/repro.nim" >/dev/null; then
  fail "repro.nim must list plug_requests in beamIntegrationTests"
fi

printf 'PASS: verify_plug_requests_test_no_silent_skip\n'
