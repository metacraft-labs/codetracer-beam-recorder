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

# `.git` is a directory in a clone and a file in a linked worktree; both are
# checkouts.
[[ -e "$trace_format_dir/.git" ]] || fail "missing sibling checkout: $trace_format_dir"

# Run from a git hook, this script inherits the recorder's GIT_DIR (and
# GIT_INDEX_FILE / GIT_WORK_TREE), which override `git -C` and would make every
# query below read the recorder's repository instead of the sibling's.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR

# floor_problem <checkout> <minimum-sha>
#
# Succeeds silently when the HEAD of <checkout> has <minimum-sha> as an
# ancestor (or is it). Otherwise prints the reason on stdout and returns 1.
#
# A SHALLOW CLONE CANNOT ANSWER THE QUESTION. CI provisions the sibling through
# the shared clone-siblings action, which clones exactly the pinned commit with
# `--depth 1`: the floor commit is then absent and the ancestry above the
# shallow boundary is cut off, so `cat-file` and `merge-base --is-ancestor`
# would report "missing" for a pin that does contain the floor. Before asking,
# a shallow checkout fetches the full history of its HEAD from its `origin`
# (`git fetch --unshallow origin <HEAD>`, see
# https://git-scm.com/docs/git-fetch#Documentation/git-fetch.txt---unshallow).
# The two checks below then run unchanged, so the answer is the one a full
# clone gives. A checkout that is not shallow never fetches. A failed fetch is
# a failure of this check, never a skip: an unanswered floor is not a passed
# one.
floor_problem() {
  local dir="$1" minimum="$2" head shallow fetch_output
  head="$(git -C "$dir" rev-parse --verify HEAD 2>&1)" || {
    printf 'cannot read HEAD of %s: %s\n' "$dir" "$head"
    return 1
  }
  shallow="$(git -C "$dir" rev-parse --is-shallow-repository 2>&1)" || {
    printf 'cannot tell whether %s is a shallow clone: %s\n' "$dir" "$shallow"
    return 1
  }
  if [[ "$shallow" == "true" ]]; then
    fetch_output="$(git -C "$dir" fetch --quiet --unshallow origin "$head" 2>&1)" || {
      printf '%s is a shallow clone at %s, so whether it contains %s cannot be answered from it, and fetching its history from origin (%s) failed: %s\n' \
        "$dir" "$head" "$minimum" "$(git -C "$dir" remote get-url origin 2>&1)" "$fetch_output"
      return 1
    }
  fi
  git -C "$dir" cat-file -e "$minimum^{commit}" 2>/dev/null || {
    printf '%s does not contain %s at all; fetch it\n' "$dir" "$minimum"
    return 1
  }
  git -C "$dir" merge-base --is-ancestor "$minimum" "$head" || {
    printf '%s HEAD is %s, which does not contain %s — the span API this recorder needs is missing\n' \
      "$dir" "$head" "$minimum"
    return 1
  }
}

if ! problem="$(floor_problem "$trace_format_dir" "$minimum_sha")"; then
  fail "codetracer-trace-format: $problem"
fi
actual_sha="$(git -C "$trace_format_dir" rev-parse HEAD)"

cd "$repo_root"

if [[ "${CODETRACER_BEAM_RECORDER_VERIFY_TRACE_FORMAT_IN_DEV_SHELL:-0}" != "1" ]] &&
  (! command -v cargo >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1); then
  if command -v repro >/dev/null 2>&1; then
    CODETRACER_BEAM_RECORDER_VERIFY_TRACE_FORMAT_IN_DEV_SHELL=1 \
      exec repro exec "$repo_root" -- bash "$0" "$@"
  fi

  if command -v nix >/dev/null 2>&1; then
    CODETRACER_BEAM_RECORDER_VERIFY_TRACE_FORMAT_IN_DEV_SHELL=1 \
      exec nix develop "$repo_root" --command bash "$0" "$@"
  fi

  fail "cargo and jq are required; enter the dev shell or install repro/nix"
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

# --- positive controls: floor_problem itself -----------------------------------
#
# Each control builds a throwaway upstream repository and a clone of it, and
# asserts both the verdict and the reason. They run with no user or system git
# configuration, so a signing or hook setting on the host cannot change them.
# The upstream history is:
#
#   root --- floor --- tip        (main)
#      \
#       `--- side                (side: never contains floor)
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
control_problems=()
(
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=control GIT_AUTHOR_EMAIL=control@example.invalid
  export GIT_COMMITTER_NAME=control GIT_COMMITTER_EMAIL=control@example.invalid
  upstream="$scratch/upstream"
  git init --quiet --initial-branch=main "$upstream"
  git -C "$upstream" commit --quiet --allow-empty -m root
  git -C "$upstream" commit --quiet --allow-empty -m floor
  floor="$(git -C "$upstream" rev-parse HEAD)"
  git -C "$upstream" commit --quiet --allow-empty -m tip
  git -C "$upstream" branch --quiet side HEAD~2
  git -C "$upstream" checkout --quiet side
  git -C "$upstream" commit --quiet --allow-empty -m side
  git -C "$upstream" checkout --quiet main
  # file:// so that --depth is honoured (a plain local path ignores it).
  url="file://$upstream"

  # control <name> <expect: pass|fail> <expected-substring> -- <checkout>
  control() {
    local name="$1" expect="$2" needle="$3" dir="$4" out status=0
    out="$(floor_problem "$dir" "$floor")" || status=$?
    if [[ "$expect" == pass && "$status" -ne 0 ]]; then
      printf 'control %s: expected a pass, got: %s\n' "$name" "$out"
    elif [[ "$expect" == fail && "$status" -eq 0 ]]; then
      printf 'control %s: expected a failure, got a pass\n' "$name"
    elif [[ -n "$needle" ]] && ! grep -Fq -- "$needle" <<<"$out"; then
      printf "control %s: missing '%s' in: %s\n" "$name" "$needle" "$out"
    fi
  }

  # The shape CI has: a depth-1 clone of a pin that contains the floor. It must
  # pass, and it must have fetched the history to do so.
  git clone --quiet --depth 1 --branch main "$url" "$scratch/shallow-tip"
  [[ "$(git -C "$scratch/shallow-tip" rev-parse --is-shallow-repository)" == true ]] ||
    printf 'control shallow-tip: the clone is not shallow, so it tests nothing\n'
  control shallow-tip pass "" "$scratch/shallow-tip"
  [[ "$(git -C "$scratch/shallow-tip" rev-parse --is-shallow-repository)" == false ]] ||
    printf 'control shallow-tip: passed without fetching the history\n'

  # A depth-1 clone of a pin that does NOT contain the floor still fails.
  git clone --quiet --depth 1 --branch side "$url" "$scratch/shallow-side"
  control shallow-side fail "does not contain $floor at all" "$scratch/shallow-side"

  # A shallow clone whose origin cannot be reached fails, loudly.
  git clone --quiet --depth 1 --branch main "$url" "$scratch/shallow-offline"
  git -C "$scratch/shallow-offline" remote set-url origin "file://$scratch/no-such-repository"
  control shallow-offline fail "is a shallow clone at" "$scratch/shallow-offline"

  # A full clone answers from what it has: its origin is unreachable, so a
  # pass proves it did not fetch.
  git clone --quiet --branch main "$url" "$scratch/full-tip"
  git -C "$scratch/full-tip" remote set-url origin "file://$scratch/no-such-repository"
  control full-tip pass "" "$scratch/full-tip"

  # A full clone checked out below the floor fails, though it holds the floor.
  git clone --quiet --branch main "$url" "$scratch/full-old"
  git -C "$scratch/full-old" checkout --quiet --detach HEAD~2
  control full-old fail "which does not contain $floor" "$scratch/full-old"
) >"$scratch/controls.out" 2>&1 || control_problems+=("controls could not be set up: $(cat "$scratch/controls.out")")
while IFS= read -r line; do
  [[ -n "$line" ]] && control_problems+=("$line")
done <"$scratch/controls.out"
if [[ "${#control_problems[@]}" -gt 0 ]]; then
  printf 'FAIL: %s\n' "${control_problems[@]}" >&2
  exit 1
fi

printf 'PASS: codetracer-trace-format sibling is %s, which contains the required %s\n' "$actual_sha" "$minimum_sha"
