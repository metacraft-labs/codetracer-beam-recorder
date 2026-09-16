#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workspace_root="$(cd "$repo_root/.." && pwd)"
trace_format_dir="$workspace_root/codetracer-trace-format"
# The sibling must be AT OR NEWER THAN this commit, which is the one that
# exposed the span API to Rust consumers ("feat(spans): expose the span API and
# span-stream reader to Rust consumers"). `NimTraceWriter::register_span`,
# `next_step_index` and `read_span_stream_json` do not exist before it, so the
# recorder cannot build against anything older.
#
# ANCESTRY, NOT EQUALITY. This used to demand the sibling be at exactly this
# commit, which made the check fail on every writer commit — including the ones
# this recorder needs. A gate that cannot pass is a gate everyone learns to
# bypass, and then it is not checking anything: the real requirement is a floor,
# so that is what is tested.
minimum_sha="f4741ac3cbd232759a617d8d0b74fa39006ee7ec"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -d "$trace_format_dir/.git" ]] || fail "missing sibling checkout: $trace_format_dir"

actual_sha="$(git -C "$trace_format_dir" rev-parse HEAD)"
git -C "$trace_format_dir" cat-file -e "$minimum_sha^{commit}" 2>/dev/null ||
  fail "codetracer-trace-format does not contain $minimum_sha at all; fetch it"
git -C "$trace_format_dir" merge-base --is-ancestor "$minimum_sha" "$actual_sha" ||
  fail "codetracer-trace-format HEAD is $actual_sha, which does not contain $minimum_sha — the span API this recorder needs is missing"

cd "$repo_root"

if [[ "${CODETRACER_BEAM_RECORDER_VERIFY_TRACE_FORMAT_IN_DEV_SHELL:-0}" != "1" ]] &&
  (! command -v cargo >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1); then
  if command -v direnv >/dev/null 2>&1; then
    CODETRACER_BEAM_RECORDER_VERIFY_TRACE_FORMAT_IN_DEV_SHELL=1 \
      exec direnv exec "$repo_root" bash "$0" "$@"
  fi

  if command -v nix >/dev/null 2>&1; then
    CODETRACER_BEAM_RECORDER_VERIFY_TRACE_FORMAT_IN_DEV_SHELL=1 \
      exec nix develop "$repo_root" --command bash "$0" "$@"
  fi

  fail "cargo and jq are required; enter the dev shell or install direnv/nix"
fi

grep -Fq 'codetracer_trace_writer_nim = { path = "../codetracer-trace-format/codetracer_trace_writer_nim" }' Cargo.toml ||
  fail "Cargo.toml must source codetracer_trace_writer_nim from the pinned sibling path"

grep -Fq 'codetracer_trace_reader = { path = "../codetracer-trace-format/codetracer_trace_reader" }' Cargo.toml ||
  fail "Cargo.toml must source codetracer_trace_reader from the pinned sibling path"

metadata="$(cargo metadata --locked --format-version 1)"

printf '%s\n' "$metadata" |
  jq -e --arg root "$workspace_root" '
    [.packages[]
      | select(.name == "codetracer_trace_writer_nim" or .name == "codetracer_trace_reader" or .name == "codetracer_trace_writer")
      | .manifest_path
      | startswith($root + "/codetracer-trace-format/")]
    | length == 3 and all
  ' >/dev/null ||
  fail "Cargo metadata did not resolve trace writer/reader crates from the sibling codetracer-trace-format checkout"

printf 'PASS: codetracer-trace-format sibling is %s, which contains the required %s\n' "$actual_sha" "$minimum_sha"
