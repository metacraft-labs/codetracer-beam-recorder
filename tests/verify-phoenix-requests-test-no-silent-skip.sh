#!/usr/bin/env bash
set -euo pipefail

# RS-M8 verification guard for tests/integration/phoenix_requests_test.exs.
#
# The two claims the milestone asks Phoenix for are `http.route` (the routed
# pattern, not the raw path) and a recorded 404, so those are exactly what this
# gate refuses to let anyone quietly drop.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_file="$repo_root/tests/integration/phoenix_requests_test.exs"
helpers="$repo_root/tests/integration/support/span_stream_helpers.exs"
fixture_dir="$repo_root/test-programs/elixir/phoenix_web"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -f "$test_file" ]] ||
  fail "tests/integration/phoenix_requests_test.exs is missing; RS-M8 requires it"

[[ -f "$helpers" ]] ||
  fail "tests/integration/support/span_stream_helpers.exs is missing"

# Everything below greps the EXECUTABLE BODY, not the whole file: the suite's
# `@moduledoc` names every claim this gate pins, so grepping the raw file would
# let someone delete the assertions and keep the gate green on the prose alone.
test_body="$(awk '/^  @moduledoc """/ {skip = 1; next} skip && /^  """$/ {skip = 0; next} !skip' "$test_file")"

for required in \
  "$fixture_dir/mix.exs" \
  "$fixture_dir/mix.lock" \
  "$fixture_dir/config/config.exs" \
  "$fixture_dir/lib/phoenix_web.ex" \
  "$fixture_dir/lib/phoenix_web/router.ex" \
  "$fixture_dir/lib/phoenix_web/endpoint.ex" \
  "$fixture_dir/lib/phoenix_web/traced_endpoint.ex" \
  "$fixture_dir/lib/phoenix_web/user_controller.ex"; do
  [[ -f "$required" ]] || fail "$required missing"
done

grep -Fq ':phoenix,' "$fixture_dir/mix.exs" ||
  fail "the phoenix_web demo must depend on the real phoenix package"

grep -Fq 'use Phoenix.Endpoint' "$fixture_dir/lib/phoenix_web/endpoint.ex" ||
  fail "the phoenix_web demo must use a real Phoenix.Endpoint"

grep -Fq 'use Phoenix.Router' "$fixture_dir/lib/phoenix_web/router.ex" ||
  fail "the phoenix_web demo must use a real Phoenix.Router"

grep -Fq 'CodetracerBeamRecorder.Plug' "$fixture_dir/lib/phoenix_web/traced_endpoint.ex" ||
  fail "the phoenix_web demo must install the recorder's Plug middleware"

grep -Fq 'phoenix_requests_land_in_span_stream' <<<"$test_body" ||
  fail "$test_file must contain test \"phoenix_requests_land_in_span_stream\""

grep -Fq 'recorder_binary!' "$helpers" ||
  fail "the span helpers must invoke the real recorder binary — no mock recorder"

grep -Fq 'read-spans' "$helpers" ||
  fail "spans must be read back through the recorder's read-spans subcommand"

grep -Fq '/api/users/:user_id' <<<"$test_body" ||
  fail "phoenix_requests_test must assert http.route is the ROUTED PATTERN, not the raw path"

grep -Fq '/does/not/exist' <<<"$test_body" ||
  fail "phoenix_requests_test must record a request that matched no route (the 404 case)"

grep -Fq 'a 404 is an error status' <<<"$test_body" ||
  fail "phoenix_requests_test must assert the 404's recorded status"

# Refuse silent-skip patterns.
if grep -E '@tag[[:space:]]+:?skip' "$test_file" >/dev/null; then
  fail "phoenix_requests_test must not be tagged :skip"
fi

if grep -E 'System\.get_env\("[^"]+"\)[^,]*\|\|[[:space:]]*ExUnit' "$test_file" >/dev/null; then
  fail "phoenix_requests_test must not bail out via env var"
fi

if ! grep -F 'tests/integration/phoenix_requests_test.exs' "$repo_root/Justfile" >/dev/null; then
  fail "Justfile must run tests/integration/phoenix_requests_test.exs as part of \`just test-integration\`"
fi

if ! grep -F 'phoenix_requests' "$repo_root/repro.nim" >/dev/null; then
  fail "repro.nim must list phoenix_requests in beamIntegrationTests"
fi

printf 'PASS: verify_phoenix_requests_test_no_silent_skip\n'
