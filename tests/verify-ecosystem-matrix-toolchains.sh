#!/usr/bin/env bash
# Every leg of ci.yml's `ecosystem-matrix` job evaluates to the toolchain it
# names, from a revision flake.lock pins.
#
# The job builds each leg's toolchain with one `nix shell <installable>...`
# whose BEAM installables come from the leg's `matrix` entry. M17 of the BEAM
# recorder plan states the matrix as OTP 26 + Elixir 1.16 and OTP 27 +
# Elixir 1.17. The OTP 26 leg used to name `nixpkgs#beam.packages.erlang_26...`
# with no `--inputs-from`, so `nixpkgs` meant the runner's flake REGISTRY
# entry, whatever revision that host happened to carry. Once nixpkgs removed
# `erlang_26` as end-of-life the leg died at evaluation
# ("'erlang_26' has been removed, as it is EOL") and the floor went untested.
# This check fails on:
#   - an `ecosystem-matrix` toolchain step whose `nix shell` lacks
#     `--inputs-from .`, so its flake references resolve through the registry
#     instead of this repo's flake.lock;
#   - an installable whose flake is not a root input of flake.lock (it would
#     silently fall back to the registry), or that is not `<input>#<attr>`;
#   - a leg whose installables do not evaluate at the locked revision;
#   - a leg whose Erlang major is not the leg's `otp` major, or whose Elixir
#     version is not exactly the leg's `elixir`.
#
# The evaluation is real `nix eval` against the committed flake.lock and the
# real ci.yml. The audit is also run against synthetic workflows as a positive
# control (a registry-resolved leg, an unlocked flake, an evaluation failure
# and a version mismatch must each be caught), so a parser change that made it
# see nothing fails here too. Nothing is mocked.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

if [[ "${CODETRACER_BEAM_RECORDER_VERIFY_MATRIX_IN_DEV_SHELL:-0}" != "1" ]] &&
  (! command -v yq >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1); then
  if command -v nix >/dev/null 2>&1; then
    CODETRACER_BEAM_RECORDER_VERIFY_MATRIX_IN_DEV_SHELL=1 \
      exec nix develop "$repo_root" --command bash "$0" "$@"
  fi
  fail "yq and jq are required; enter the dev shell"
fi
command -v nix >/dev/null 2>&1 || fail "nix is required to evaluate the matrix toolchains"

cd "$repo_root"

locked_inputs="$(jq -c '.nodes.root.inputs | keys' flake.lock)"

# nix eval of one attribute of one installable, resolved the way the CI step
# resolves it. Prints the value; on failure prints nix's last error line and
# returns 1.
eval_attr() {
  local installable="$1" attr="$2" out err
  err="$(mktemp)"
  # stderr is kept apart: nix warns there (e.g. "Git tree ... is dirty"),
  # and only stdout is the value.
  if out="$(nix eval --raw --inputs-from "$repo_root" "$installable.$attr" 2>"$err")"; then
    rm -f "$err"
    printf '%s' "$out"
  else
    printf '%s' "$(grep -E 'error' "$err" | tail -n 1 | sed 's/^[[:space:]]*//')"
    rm -f "$err"
    return 1
  fi
}

# Audits the `ecosystem-matrix` job of one workflow file. Prints one line per
# problem and nothing when every leg holds.
audit() {
  local workflow="$1" job legs leg_count i
  job="$(yq -o=json '.jobs["ecosystem-matrix"]' "$workflow")"
  if [[ "$job" == "null" ]]; then
    echo "$workflow: no ecosystem-matrix job"
    return
  fi
  legs="$(jq -c '.strategy.matrix.include // []' <<<"$job")"
  leg_count="$(jq 'length' <<<"$legs")"
  if [[ "$leg_count" -eq 0 ]]; then
    echo "$workflow: ecosystem-matrix has no matrix.include legs"
    return
  fi

  # The toolchain step: the one whose script runs `nix shell`. Comment lines
  # are dropped, and the command is read up to its `-c` (the inner script).
  local script
  script="$(jq -r '[.steps[] | select((.run // "") | test("\\bnix\\s+shell\\b")) | .run] | first // ""' <<<"$job" |
    grep -v '^[[:space:]]*#' | tr '\\\n' '  ')"
  if [[ -z "$script" ]]; then
    echo "$workflow: ecosystem-matrix has no 'nix shell' toolchain step"
    return
  fi
  local command="${script#*nix shell}"
  command="${command%% -c *}"
  if ! grep -Eq '(^|[[:space:]])--inputs-from[[:space:]]+\.([[:space:]]|$)' <<<"$command"; then
    echo "$workflow: the toolchain 'nix shell' has no '--inputs-from .'; its flake references resolve through the runner's registry, not flake.lock"
  fi

  for ((i = 0; i < leg_count; i++)); do
    local leg otp elixir name tokens token installable flake erlang_ver elixir_ver value
    leg="$(jq -c ".[$i]" <<<"$legs")"
    otp="$(jq -r '.otp // ""' <<<"$leg")"
    elixir="$(jq -r '.elixir // ""' <<<"$leg")"
    name="leg otp=$otp elixir=$elixir"
    # Substitute the leg's matrix values the way the runner does.
    tokens="$command"
    while IFS=$'\t' read -r key val; do
      tokens="${tokens//"\${{ matrix.$key }}"/$val}"
    done < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' <<<"$leg")
    # shellcheck disable=SC2016 # a literal ${{, i.e. an expression the runner would not have substituted
    if [[ "$tokens" == *'${{'* ]]; then
      echo "$workflow: $name: unresolved expression in toolchain command: $tokens"
      continue
    fi

    local erlang_installable="" elixir_installable=""
    for token in $tokens; do
      token="${token//\"/}"
      token="${token//\'/}"
      case "$token" in
      -* | .) continue ;;
      esac
      if [[ "$token" != *"#"* ]]; then
        echo "$workflow: $name: installable '$token' is not '<flake-input>#<attr>'"
        continue
      fi
      flake="${token%%#*}"
      if ! jq -e --arg f "$flake" 'index($f) != null' <<<"$locked_inputs" >/dev/null; then
        echo "$workflow: $name: '$token' names flake '$flake', which flake.lock does not pin as a root input"
        continue
      fi
      installable="$token"
      case "$installable" in
      *"#beam.packages."*".erlang") erlang_installable="$installable" ;;
      *"#beam.packages."*".elixir_"*) elixir_installable="$installable" ;;
      esac
      if ! value="$(eval_attr "$installable" name)"; then
        echo "$workflow: $name: '$installable' does not evaluate: $value"
      fi
    done

    if [[ -z "$erlang_installable" || -z "$elixir_installable" ]]; then
      echo "$workflow: $name: no beam.packages.<set>.erlang / .elixir_<v> installable in the toolchain"
      continue
    fi
    if erlang_ver="$(eval_attr "$erlang_installable" version)"; then
      [[ "${erlang_ver%%.*}" == "${otp%%.*}" ]] ||
        echo "$workflow: $name: '$erlang_installable' is Erlang/OTP $erlang_ver, not OTP ${otp%%.*}"
    fi
    if elixir_ver="$(eval_attr "$elixir_installable" version)"; then
      [[ "$elixir_ver" == "$elixir" ]] ||
        echo "$workflow: $name: '$elixir_installable' is Elixir $elixir_ver, not $elixir"
    fi
  done
}

# --- The real workflow. ---
problems="$(audit .github/workflows/ci.yml)"
if [[ -n "$problems" ]]; then
  printf '%s\n' "$problems" >&2
  fail "ci.yml's ecosystem-matrix legs do not evaluate to their stated toolchains"
fi
echo "ok: every ecosystem-matrix leg evaluates to its stated OTP/Elixir from flake.lock"

# --- Positive controls: each synthetic defect must be reported. ---
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# Writes a one-leg ecosystem-matrix workflow. $1 = file, $2 = extra
# nix-shell flags, $3 = otp, $4 = elixir, $5 = erlang installable,
# $6 = elixir installable.
synthetic() {
  cat >"$1" <<YAML
jobs:
  ecosystem-matrix:
    strategy:
      matrix:
        include:
          - otp: "$3"
            elixir: "$4"
            erlang-attr: "$5"
            elixir-attr: "$6"
    steps:
      - run: |
          nix shell $2 \\
            "\${{ matrix.erlang-attr }}" \\
            "\${{ matrix.elixir-attr }}" \\
            nixpkgs#just \\
            -c bash -c 'just build'
YAML
}

expect_caught() {
  local label="$1" pattern="$2" file="$3" out
  out="$(audit "$file")"
  grep -q -- "$pattern" <<<"$out" ||
    fail "positive control '$label' was not caught (expected /$pattern/), audit said: ${out:-<nothing>}"
  echo "ok: positive control '$label' caught"
}

synthetic "$scratch/registry.yml" "" 27 1.17.3 \
  "nixpkgs#beam.packages.erlang_27.erlang" "nixpkgs#beam.packages.erlang_27.elixir_1_17"
expect_caught "registry-resolved toolchain" "no '--inputs-from .'" "$scratch/registry.yml"

synthetic "$scratch/unlocked.yml" "--inputs-from ." 27 1.17.3 \
  "nixpkgs-unpinned#beam.packages.erlang_27.erlang" "nixpkgs#beam.packages.erlang_27.elixir_1_17"
expect_caught "flake not pinned by flake.lock" "does not pin as a root input" "$scratch/unlocked.yml"

# erlang_26 in the main nixpkgs input: the exact failure this check exists for.
synthetic "$scratch/removed.yml" "--inputs-from ." 26 1.16.3 \
  "nixpkgs#beam.packages.erlang_26.erlang" "nixpkgs#beam.packages.erlang_26.elixir_1_16"
expect_caught "attribute removed from the locked nixpkgs" "does not evaluate" "$scratch/removed.yml"

synthetic "$scratch/mismatch.yml" "--inputs-from ." 26 1.16.3 \
  "nixpkgs#beam.packages.erlang_27.erlang" "nixpkgs#beam.packages.erlang_27.elixir_1_17"
expect_caught "Erlang major differs from the leg's otp" "not OTP 26" "$scratch/mismatch.yml"
expect_caught "Elixir differs from the leg's elixir" "is Elixir 1.17.3, not 1.16.3" "$scratch/mismatch.yml"

echo "ok: ecosystem-matrix toolchain audit"
