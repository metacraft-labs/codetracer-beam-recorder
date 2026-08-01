#!/usr/bin/env bash
set -euo pipefail

# RS-M8 follow-up verification guard for tests/integration/nested_requests_test.exs.
#
# The suite is only worth anything if the inner request is genuinely served
# INSIDE the outer one, on the same process, and if what is asserted is that
# the outer request kept being recorded afterwards. Both are easy to weaken
# into a tautology -- two sibling requests, or a span-count assertion that
# passes with the bug present -- so this gate pins them.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_file="$repo_root/tests/integration/nested_requests_test.exs"
helpers="$repo_root/tests/integration/support/span_stream_helpers.exs"
fixture_dir="$repo_root/test-programs/elixir/plug_web"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -f "$test_file" ]] ||
  fail "tests/integration/nested_requests_test.exs is missing"

[[ -f "$helpers" ]] ||
  fail "tests/integration/support/span_stream_helpers.exs is missing"

[[ -f "$fixture_dir/lib/plug_web/nested.ex" ]] ||
  fail "the plug_web demo must carry the nesting handler at lib/plug_web/nested.ex"

# The nesting has to be real: a second request through the same endpoint, in
# the handler's own process. A Task or a spawn would make it two siblings.
grep -Fq 'PlugWeb.Endpoint.call' "$fixture_dir/lib/plug_web/nested.ex" ||
  fail "the inner request must go through the real endpoint pipeline"

if grep -Eq 'Task\.|spawn|Process\.spawn' "$fixture_dir/lib/plug_web/nested.ex"; then
  fail "the inner request must be served on the OUTER request's process; spawning makes it a sibling, not a nested request"
fi

grep -Fq '/proxy/:target' "$fixture_dir/lib/plug_web/router.ex" ||
  fail "the plug_web router must expose the nesting route"

grep -Fq 'CT_PLUG_WEB_NESTED' "$fixture_dir/lib/plug_web.ex" ||
  fail "the demo must expose the nested schedule"

# Everything below greps the EXECUTABLE BODY, not the whole file: the suite's
# `@moduledoc` names every claim this gate pins, so grepping the raw file would
# let someone delete the assertions and keep the gate green on the prose alone.
test_body="$(awk '/^  @moduledoc """/ {skip = 1; next} skip && /^  """$/ {skip = 0; next} !skip' "$test_file")"

grep -Fq 'nested_requests_keep_the_outer_request_traced' <<<"$test_body" ||
  fail "$test_file must contain test \"nested_requests_keep_the_outer_request_traced\""

grep -Fq 'recorder_binary!' "$helpers" ||
  fail "the span helpers must invoke the real recorder binary -- no mock recorder"

grep -Fq 'read-spans' "$helpers" ||
  fail "spans must be read back through the recorder's read-spans subcommand"

grep -Fq 'H.meta(outer)["beam.pid"] == H.meta(inner)["beam.pid"]' <<<"$test_body" ||
  fail "the suite must assert both requests were served on ONE process; without it this is a sibling-requests test"

grep -Fq 'inner["end_step"] <= outer["end_step"]' <<<"$test_body" ||
  fail "the suite must assert the inner span nests inside the outer span"

# The assertion the bug fails. Both spans settle either way, so a suite that
# only counts spans passes with the outer request silenced.
grep -Fq 'tail_calls >= @post_inner_calls' <<<"$test_body" ||
  fail "the suite must assert the outer request's post-inner traced calls were recorded; a span-count assertion alone passes with the bug present"

grep -Fq 'step_marker' <<<"$test_body" ||
  fail "the post-inner work must be identified by the function the handler actually calls"

# Refuse silent-skip patterns.
if grep -E '@tag[[:space:]]+:?skip' "$test_file" >/dev/null; then
  fail "nested_requests_test must not be tagged :skip"
fi

if grep -E 'System\.get_env\("[^"]+"\)[^,]*\|\|[[:space:]]*ExUnit' "$test_file" >/dev/null; then
  fail "nested_requests_test must not bail out via env var"
fi

if ! grep -F 'tests/integration/nested_requests_test.exs' "$repo_root/Justfile" >/dev/null; then
  fail "Justfile must run tests/integration/nested_requests_test.exs as part of \`just test-integration\`"
fi

if ! grep -F 'nested_requests_test' "$repo_root/repro.nim" >/dev/null; then
  fail "repro.nim must list nested_requests_test in beamIntegrationTests"
fi

printf 'PASS: verify_nested_requests_test_no_silent_skip\n'
