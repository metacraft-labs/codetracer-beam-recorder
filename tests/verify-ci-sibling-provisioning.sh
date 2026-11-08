#!/usr/bin/env bash
# Every CI job takes the trace-format siblings at the revision repro.lock pins.
#
# The recorder crate path-depends on ../codetracer-trace-format (Cargo.toml),
# and codetracer_trace_writer_nim's build script compiles
# ../codetracer-trace-format-nim. Which revision of each this commit builds
# against is recorded in ONE place: the `deps` of the committed repro.lock. The
# only approved way for a workflow to reproduce it is metacraft-github-actions
# `clone-siblings`, directly or through `setup-dev-env` (which calls it): it
# reads that lock and clones each sibling to ../<name> at the pinned commit.
#
# ci.yml built the crate in five jobs with no sibling on disk at all, so every
# one of them failed before compiling anything; elsewhere in the fleet the
# same gap was papered over with hand-written `git clone --branch main` steps
# that picked a revision of their own. This check fails on:
#   - a job that builds the crate (cargo, `just build|test|lint|...`,
#     `nix build`, `nix develop --command just ...`) before an approved step
#     has provisioned every sibling the crate needs;
#   - a sibling the lock pins being provisioned any other way: `git clone` of
#     it, `actions/checkout` / `clone-repo` of it, moving a cloned sibling with
#     `git -C ../<name> checkout|fetch|reset`, `.github/sibling-pins`, or a
#     literal `name=ref` in a `siblings:` list (a `${{ }}` dispatch override,
#     which is empty unless a human supplies a ref, is allowed);
#   - a `nix build` of this flake that does not `--override-input` every
#     sibling flake input with its lock-pinned clone at ../<name> (it would
#     build the revision flake.lock records instead);
#   - .github/sibling-repos not naming a sibling the crate needs, or repro.lock
#     not pinning one (clone-siblings refuses an unpinned sibling).
#
# The audit is also run against synthetic workflows as a positive control, so
# a parser change that made it see nothing fails here too. Nothing is mocked:
# the real workflow files, Cargo.toml and repro.lock are read.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

if [[ "${CODETRACER_BEAM_RECORDER_VERIFY_CI_SIBLINGS_IN_DEV_SHELL:-0}" != "1" ]] &&
  (! command -v yq >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1); then
  if command -v nix >/dev/null 2>&1; then
    CODETRACER_BEAM_RECORDER_VERIFY_CI_SIBLINGS_IN_DEV_SHELL=1 \
      exec nix develop "$repo_root" --command bash "$0" "$@"
  fi
  fail "yq and jq are required; enter the dev shell"
fi

cd "$repo_root"

# The audit of one workflow (as JSON on stdin). Prints one line per problem.
audit_jq="$(
  cat <<'JQ'
def approved: test("^metacraft-labs/metacraft-github-actions/(setup-dev-env|clone-siblings)@");
def pinned($n): any($pinned[]; . == $n);
def no_comments: split("\n") | map(select(test("^\\s*#") | not)) | join("\n");
def build_re:
  "\\bcargo\\s+(build|test|run|nextest|clippy|check|bench|metadata)\\b"
  + "|\\bjust\\s+(build|build-native|test|test-[a-z-]+|lint|release-check|bench|build-package|build-hex)\\b"
  + "|\\brepro\\s+(build|test)\\b"
  + "|\\bnix\\s+build\\b"
  + "|\\bnix\\s+develop\\b.*--command\\s+(bash\\s+-c\\s+[\"'])?just\\b";
def build_label:
  if (.uses // "") | test("^PyO3/maturin-action@") then .uses
  else ((.run // "") | no_comments | [match(build_re)] | if length > 0 then .[0].string else null end)
  end;
# clone-siblings grammar: name, owner/name, name=ref, name!=ref; an empty ref
# means "use the lock". An empty list means .github/sibling-repos. A `${{ }}`
# expression is collapsed to one token first: the runner substitutes it before
# clone-siblings splits the list, so its inner spaces never separate entries.
def entries($raw):
  if ($raw | test("\\S")) then
    [$raw | gsub("\\$\\{\\{[^}]*\\}\\}"; "${{expression}}") | splits("\\s+") | select(length > 0 and (startswith("#") | not))
      | if index("=") == null then {name: (split("/") | last), ref: null}
        else index("=") as $i
          | {name: (.[:$i] | rtrimstr("!") | split("/") | last),
             ref: (.[$i + 1:] | if . == "" then null else . end)}
        end]
  else [$declared[] | {name: ., ref: null}]
  end;
def audit_job($job):
  (.steps // []) as $steps
  | reduce range(0; $steps | length) as $i ({prov: [], out: []};
      $steps[$i] as $s
      | "\($file): job '\($job)' step \($i + 1) (\($s.name // $s.uses // "run"))" as $where
      | ($s.uses // "") as $uses
      | ($s.with // {}) as $with
      | (($s.run // "") | no_comments) as $script
      | if ($s | tojson | test("sibling-pins")) then
          .out += ["\($where): reads .github/sibling-pins; sibling revisions come from repro.lock"]
        else . end
      | if ($uses | approved) then
          entries(($with.siblings // "") | tostring) as $es
          | .out += [$es[] | select(.ref != null and (.ref | startswith("${{") | not) and pinned(.name))
              | "\($where): pins sibling '\(.name)' to '\(.ref)' instead of the revision repro.lock pins"]
          | .prov += [$es[].name]
        else
          (if ($uses | startswith("actions/checkout@")) and ($with.repository != null)
            then ($with.repository | split("/") | last) else null end) as $co
          | if $co != null and pinned($co) then
              .out += ["\($where): checks out lock-pinned sibling '\($co)' with actions/checkout"]
            else . end
          | (if ($uses | test("/clone-repo@")) then (($with.repo // "") | split("/") | last) else null end) as $cr
          | if $cr != null and pinned($cr) then
              .out += ["\($where): clones lock-pinned sibling '\($cr)' with clone-repo at '\($with.ref)'"]
            else . end
          | if ($script | test("\\bgit\\s+clone\\b|\\bgh\\s+repo\\s+clone\\b")) then
              ([$script | match("github\\.com[/:][\\w.-]+/([\\w.-]+?)(?:\\.git)?(?=[\"'\\s/]|$)|\\bgh\\s+repo\\s+clone\\s+[\\w.-]+/([\\w.-]+)"; "gm")
                | [.captures[].string | select(. != null)] | first] | unique) as $cloned
              | .out += [$cloned[] | select(pinned(.)) | "\($where): hand-clones lock-pinned sibling '\(.)'"]
            else . end
          | .out += [$pinned[] as $n
              | select($script | test("\\bgit\\s+-C\\s+[\"']?[^\"'\\s]*\\.\\./" + ($n | gsub("\\."; "\\.")) + "[\"']?\\s+(checkout|fetch|reset|switch|pull)\\b"))
              | "\($where): moves lock-pinned sibling '\($n)' to another revision"]
          # A `nix build` of this flake takes the siblings from its flake
          # inputs, i.e. at the revisions flake.lock records, unless each one
          # is overridden with the lock-pinned clone at ../<name>. Only a build
          # of THIS flake counts: a step that changes directory (another
          # repo's flake, e.g. cross-repo-tests building ../codetracer) has
          # inputs of its own.
          | (($script | test("\\bnix\\s+build\\b")) and ($s["working-directory"] == null)
              and ($script | test("(^|[\\s;&|(])cd\\s") | not)) as $own_nix_build
          | .out += [if $own_nix_build then $flake_inputs[] else empty end
              | (gsub("\\."; "\\.")) as $re
              | select($script | test("--override-input\\s+" + $re + "\\s+[\"']?path:[^\\s\"']*\\.\\./" + $re + "([\"'\\s]|$)") | not)
              | "\($where): runs 'nix build' without --override-input \(.) path:../\(.), so it builds the revision flake.lock records instead of the one repro.lock pins"]
          | ($s | build_label) as $build
          | ($required - .prov) as $missing
          | if $build != null and ($missing | length) > 0 then
              .out += ["\($where): builds the crate ('\($build)') before \($missing | join(", ")) is provisioned by setup-dev-env/clone-siblings"]
            else . end
        end)
  | .out[];
if $mode == "count-builds" then
  [(.jobs // {})[] | (.steps // [])[] | select(build_label != null)] | length
else
  (.jobs // {}) | to_entries[] | .key as $job | .value | audit_job($job)
end
JQ
)"

# audit <workflow> <mode> <pinned-json> <required-json> <declared-json> <flake-inputs-json>
audit() {
  yq -o=json '.' "$1" |
    jq -r --arg file "$(basename "$1")" --arg mode "$2" \
      --argjson pinned "$3" --argjson required "$4" --argjson declared "$5" \
      --argjson flake_inputs "$6" \
      "$audit_jq"
}

# --- inputs from the repo -----------------------------------------------------

# Siblings repro.lock pins (the repo's own `self` entry is not a sibling).
pinned="$(yq -p toml -o json \
  '[.lock.deps[] | select(.revision != null and .revision != "" and .self != "true") | .name]' repro.lock)"

# Siblings a crate build needs on disk: the roots of Cargo.toml's
# `../<name>/...` path dependencies, plus codetracer-trace-format-nim, whose
# sources codetracer_trace_writer_nim's build script compiles.
required="$(
  {
    grep -oE 'path = "\.\./[^/"]+' Cargo.toml | sed 's|.*\.\./||'
    if grep -q '^codetracer_trace_writer_nim = ' Cargo.toml; then
      echo codetracer-trace-format-nim
    fi
  } | sort -u | jq -R . | jq -sc .
)"
[[ "$(jq length <<<"$required")" -gt 0 ]] || fail "found no sibling path dependency in Cargo.toml"

# The required siblings flake.nix also declares as inputs (`<name> = {`): a
# `nix build` must override each of them with its lock-pinned clone.
flake_inputs="$(
  jq -r '.[]' <<<"$required" | while IFS= read -r n; do
    if grep -Eq "^[[:space:]]+${n//./\\.}[[:space:]]*=[[:space:]]*\\{" flake.nix; then
      echo "$n"
    fi
  done | jq -R . | jq -sc .
)"

declared='[]'
if [[ -f .github/sibling-repos ]]; then
  declared="$(sed 's/#.*//' .github/sibling-repos | tr -s '[:space:]' '\n' | sed '/^$/d' | jq -R . | jq -sc .)"
fi

problems=()
missing_decl="$(jq -nr --argjson r "$required" --argjson d "$declared" '$r - $d | join(", ")')"
[[ -z "$missing_decl" ]] ||
  problems+=(".github/sibling-repos does not declare $missing_decl, which the crate build needs")
unpinned="$(jq -nr --argjson r "$required" --argjson p "$pinned" '$r - $p | join(", ")')"
[[ -z "$unpinned" ]] ||
  problems+=("repro.lock does not pin $unpinned; run 'repro lock refresh'")

builds=0
shopt -s nullglob
for wf in .github/workflows/*.yml .github/workflows/*.yaml; do
  while IFS= read -r line; do
    [[ -n "$line" ]] && problems+=("$line")
  done < <(audit "$wf" audit "$pinned" "$required" "$declared" "$flake_inputs")
  builds=$((builds + $(audit "$wf" count-builds "$pinned" "$required" "$declared" "$flake_inputs")))
done
[[ "$builds" -gt 0 ]] || problems+=("no workflow step was recognised as building the crate")

# --- positive controls: the audit itself --------------------------------------

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
c_pinned='["codetracer-trace-format","codetracer-trace-format-nim","codetracer-launcher"]'
c_required='["codetracer-trace-format","codetracer-trace-format-nim"]'

# control <name> <expected-problem-count> <expected-substring>... <<YAML
control() {
  local name="$1" want="$2" out count
  shift 2
  cat >"$scratch/$name.yml"
  out="$(audit "$scratch/$name.yml" audit "$c_pinned" "$c_required" "$c_required" "$c_required")"
  count="$(grep -c . <<<"$out" || true)"
  [[ "$count" -eq "$want" ]] ||
    problems+=("control $name: expected $want problem(s), got $count: $out")
  local needle
  for needle in "$@"; do
    grep -Fq -- "$needle" <<<"$out" || problems+=("control $name: missing '$needle' in: $out")
  done
}

# The shape ci.yml had: a crate build with no sibling on disk.
control unprovisioned 5 "builds the crate ('nix develop --command just')" \
  "builds the crate ('nix build')" "builds the crate ('just build')" <<'YAML'
jobs:
  test:
    steps:
      - uses: actions/checkout@v4
      - run: nix develop --command just test 2>&1 | tee logs/test.log
  nix-build:
    steps:
      - run: nix build .#default --print-build-logs
  matrix:
    steps:
      - run: |
          nix shell nixpkgs#cargo -c bash -c '
            just build
          '
YAML

# The hand-rolled shapes seen elsewhere in the fleet.
control hand-rolled 5 "reads .github/sibling-pins" \
  "hand-clones lock-pinned sibling 'codetracer-trace-format'" \
  "moves lock-pinned sibling 'codetracer-trace-format'" \
  "clones lock-pinned sibling 'codetracer-launcher' with clone-repo at 'main'" \
  "pins sibling 'codetracer-trace-format-nim' to 'dev'" <<'YAML'
jobs:
  build:
    steps:
      - run: |
          PINS=".github/sibling-pins"
          git clone --branch main https://github.com/metacraft-labs/codetracer-trace-format.git ../codetracer-trace-format
          git -C "../codetracer-trace-format" checkout dev || true
      - uses: metacraft-labs/metacraft-github-actions/clone-repo@dev
        with:
          repo: metacraft-labs/codetracer-launcher
          ref: main
      - uses: metacraft-labs/metacraft-github-actions/clone-siblings@dev
        with:
          siblings: |
            codetracer-trace-format
            codetracer-trace-format-nim=dev
      - run: cargo build --locked
YAML

# A list that leaves out a sibling the build needs.
control partial 1 "builds the crate ('cargo build') before codetracer-trace-format-nim is provisioned" <<'YAML'
jobs:
  build:
    steps:
      - uses: metacraft-labs/metacraft-github-actions/clone-siblings@dev
        with:
          siblings: codetracer-trace-format
      - run: cargo build --locked
YAML

# A `nix build` that overrides only one of the flake's sibling inputs: the other is
# built at the revision flake.lock records, whatever was cloned.
control flake-lock-fallback 1 \
  "runs 'nix build' without --override-input codetracer-trace-format-nim path:../codetracer-trace-format-nim" <<'YAML'
jobs:
  nix-build:
    steps:
      - uses: metacraft-labs/metacraft-github-actions/setup-dev-env@dev
        with:
          env-flavor: nix
      - run: nix build .#default --override-input codetracer-trace-format path:../codetracer-trace-format
YAML

# The approved shapes produce nothing.
control approved 0 <<'YAML'
jobs:
  default-list:
    steps:
      - uses: actions/checkout@v4
      - uses: metacraft-labs/metacraft-github-actions/setup-dev-env@dev
        with:
          env-flavor: nix
      - run: dev-exec just test
  explicit-list:
    steps:
      - uses: metacraft-labs/metacraft-github-actions/clone-siblings@dev
        with:
          siblings: |
            codetracer-trace-format
            codetracer-trace-format-nim
            codetracer-launcher!=${{ github.event.inputs.launcher_ref || inputs.x }}
      - run: |
          nix build .#default --print-build-logs \
            --override-input codetracer-trace-format path:../codetracer-trace-format \
            --override-input codetracer-trace-format-nim "path:$GITHUB_WORKSPACE/../codetracer-trace-format-nim" \
            2>&1 | tee logs/nix-build.log
  other-flake:
    steps:
      - uses: metacraft-labs/metacraft-github-actions/setup-dev-env@dev
      # Another repo's flake, with inputs of its own.
      - run: |
          cd "$GITHUB_WORKSPACE/../codetracer"
          nix build .#codetracer
  reusable:
    uses: metacraft-labs/codetracer/.github/workflows/x.yml@dev
  tooling-only:
    steps:
      # cargo build happens in another job
      - run: nix shell nixpkgs#erlang -c mix local.hex --force
YAML

if [[ "${#problems[@]}" -gt 0 ]]; then
  printf 'FAIL: %s\n' "${problems[@]}" >&2
  exit 1
fi

printf 'PASS: %d crate-building step(s) take %s from repro.lock via setup-dev-env/clone-siblings\n' \
  "$builds" "$(jq -r 'join(", ")' <<<"$required")"
