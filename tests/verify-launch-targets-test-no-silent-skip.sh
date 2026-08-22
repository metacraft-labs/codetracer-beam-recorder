#!/usr/bin/env bash
set -euo pipefail

# Guards that tests/integration/launch_targets_test.exs cannot quietly turn
# itself into a no-op.  The `elixir` and `escript` launch targets exist
# because `ct record foo.ex` used to exit 0 having recorded nothing; a suite
# that verifies them must never be able to pass for the same reason.
#
# Mirrors verify-function-trace-test-no-silent-skip.sh in spirit.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_file="$repo_root/tests/integration/launch_targets_test.exs"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

[[ -f "$test_file" ]] ||
	fail "tests/integration/launch_targets_test.exs is missing; the launch-target verification requires it"

# Both happy paths and every guard must be present by name.
for name in \
	elixir_launch_target_records_a_bare_ex_program \
	escript_launch_target_records_a_bare_erl_program \
	guard_uninstrumentable_source_dir_fails_loudly \
	guard_missing_source_dir_fails_loudly \
	guard_uninstrumented_program_fails_loudly \
	guard_escript_without_erl_source_fails_loudly \
	guard_instrumented_ebin_without_traceable_functions_fails_loudly \
	guard_module_defined_inside_a_top_level_expression_fails_loudly \
	escript_launch_target_passes_script_arguments_to_main \
	elixir_launch_target_compiles_modules_with_their_top_level_directives \
	non_beam_targets_still_run_verbatim_and_propagate_exit_codes; do
	grep -Fq "\"$name\"" "$test_file" ||
		fail "$test_file must contain test \"$name\""
done

# The real recorder binary, never a mock.
grep -Fq 'recorder_binary!' "$test_file" ||
	fail "launch_targets_test must call recorder_binary! — no mock recorder allowed"

# The launch commands under test must be the ones the desktop core actually
# sends (recorder_dispatch.nim): `-- elixir <program>` and
# `-- escript <program>`.  A suite that drove `mix` or `erl` instead would
# verify nothing about this milestone.
grep -Fq '"elixir",' "$test_file" ||
	fail 'launch_targets_test must drive the "-- elixir <program>" launch command'
grep -Fq '"escript",' "$test_file" ||
	fail 'launch_targets_test must drive the "-- escript <program>" launch command'

# The single-file fixtures both targets record.
for fixture in \
	test-programs/elixir/standalone_script/standalone_script.ex \
	test-programs/erlang/escript_program/escript_program.erl; do
	grep -Fq "$fixture" "$test_file" ||
		fail "launch_targets_test must drive $fixture"
	[[ -f "$repo_root/$fixture" ]] || fail "missing fixture: $repo_root/$fixture"
done

# The Elixir fixture must keep the shape the standalone build has to cope
# with: module definitions PLUS top-level entry code.  Without the top-level
# call the program would do nothing and the trace would be empty for an
# entirely different reason.
elixir_fixture="$repo_root/test-programs/elixir/standalone_script/standalone_script.ex"
grep -Eq '^defmodule StandaloneScript do' "$elixir_fixture" ||
	fail "$elixir_fixture must define StandaloneScript at the top level"
grep -Eq '^StandaloneScript\.main\(\)' "$elixir_fixture" ||
	fail "$elixir_fixture must call StandaloneScript.main() as TOP-LEVEL code — that is the entry point the standalone build has to separate from the module"

# The Erlang fixture must define escript's entry point.
erlang_fixture="$repo_root/test-programs/erlang/escript_program/escript_program.erl"
grep -Eq '^main\(' "$erlang_fixture" ||
	fail "$erlang_fixture must define main/1 — escript's entry point contract"

# Bundle queries must go through the recorder's read-bundle-summary
# subcommand, which wraps the real NimTraceReaderHandle.
grep -Fq 'read-bundle-summary' "$test_file" ||
	fail "launch_targets_test must verify CTFS bundles via the read-bundle-summary recorder subcommand"

# The assertions that make a vacuous pass impossible.  `function_names`,
# `call_count` and `step_count` are the decoded trace SHAPE; `recorded_output`
# is the program's own stdout read back out of the trace; the trace_meta
# checks are the defect's exact fingerprint (`"mode": "non_beam"` with an
# empty `sources` list).
for token in \
	'function_names' \
	'call_count' \
	'step_count' \
	'sidecar_call_count' \
	'recorded_output' \
	'runtime_session_delivered' \
	'runtime_session' \
	'"beam"' \
	'"non_beam"' \
	'sources'; do
	grep -Fq "$token" "$test_file" ||
		fail "launch_targets_test must assert on $token"
done

# The guards must assert a NON-ZERO exit and a NAMED diagnostic, not just
# "something went wrong".
# shellcheck disable=SC2016  # these are literal diagnostic strings, not expansions
for token in \
	'no BEAM sources were compiled into an instrumented ebin' \
	'produced no traceable functions' \
	'was not part of the instrumented standalone Elixir build' \
	'only records `.erl` sources' \
	'contains no traceable functions' \
	'inside a top-level expression'; do
	grep -Fq "$token" "$test_file" ||
		fail "launch_targets_test must assert the diagnostic text: $token"
done
grep -Fq 'status != 0' "$test_file" ||
	fail "launch_targets_test must assert that the guards exit non-zero"

# A missing toolchain must FAIL, never skip.
grep -Fq 'require_toolchain!' "$test_file" ||
	fail "launch_targets_test must hard-fail on a missing BEAM toolchain"
grep -Eq 'flunk\(' "$test_file" ||
	fail "launch_targets_test's toolchain check must flunk, not skip"

# Refuse the common silent-skip patterns.
if grep -E '@tag[[:space:]]+:?skip' "$test_file" >/dev/null; then
	fail "launch_targets_test must not be tagged :skip"
fi
if grep -E 'System\.get_env\("[^"]+"\)[^,]*\|\|[[:space:]]*ExUnit' "$test_file" >/dev/null; then
	fail "launch_targets_test must not bail out via env var"
fi

# CI must actually run it.
grep -F 'tests/integration/launch_targets_test.exs' "$repo_root/Justfile" >/dev/null ||
	fail "Justfile must run tests/integration/launch_targets_test.exs as part of \`just test-integration\`"

# The design document the targets are specified in must exist and must cover
# the two hard parts: the standalone Elixir compile and the empty-recording
# guard.  A target implemented without its spec is what produced the
# launcher/recorder disagreement in the first place.
design="$repo_root/docs/launch-targets.md"
[[ -f "$design" ]] || fail "missing design document: $design"
for heading in \
	'Instrumented compilation for a bare' \
	'The guard against silent empty recordings' \
	'Alternatives considered and rejected'; do
	grep -Fq "$heading" "$design" ||
		fail "$design must document: $heading"
done

printf 'PASS: verify_launch_targets_test_no_silent_skip\n'
