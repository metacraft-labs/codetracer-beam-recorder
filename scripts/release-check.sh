#!/usr/bin/env bash
set -euo pipefail

# M17 release readiness gate. Exits non-zero if any of the following
# conditions does not hold for the current working tree:
#
#   1. Cargo.toml package metadata (name, license, repository,
#      description) is in place and the binary name is the canonical
#      `codetracer-beam-recorder`.
#   2. mix.exs Hex package metadata exists and is consistent with
#      Cargo.toml's version.
#   3. rebar3_codetracer/src/rebar3_codetracer.app.src application
#      version matches Cargo.toml.
#   4. CHANGELOG.md exists and references the current version.
#   5. LICENSE exists.
#   6. The recorder binary builds.
#   7. The recorder binary surfaces the same version as Cargo.toml on
#      `--version`.
#
# Sibling revisions for the downstream regression set
# (codetracer-trace-format, codetracer, codetracer-vscode-extension) are
# resolved by CI through the repo-workspaces workspace lock
# (scripts/resolve-sibling-rev.sh); the legacy committed sibling-pin
# files are forbidden by the canonical repo requirements
# (runquota/scripts/check_repo_requirements.sh) and are no longer checked
# here.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

bold() { printf '\n=== %s ===\n' "$*"; }
ok() { printf 'OK: %s\n' "$*"; }
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

extract_cargo_version() {
  grep -E '^version = "' Cargo.toml | head -n1 | cut -d '"' -f2
}

extract_mix_version() {
  # mix.exs declares the version through a module attribute
  # (`@version "0.1.0"`) which is then referenced as `version:
  # @version` inside `project/0`. Read the @version literal.
  grep -E '^[[:space:]]*@version[[:space:]]+"' mix.exs |
    head -n1 |
    cut -d '"' -f2
}

extract_app_src_version() {
  grep -E '\{vsn,' rebar3_codetracer/src/rebar3_codetracer.app.src |
    head -n1 |
    sed -E 's/.*\{vsn,\s*"([^"]+)"\}.*/\1/'
}

# ---------- 1. Cargo.toml metadata ----------
bold "Cargo.toml metadata"
[[ -f Cargo.toml ]] || fail "Cargo.toml missing"

cargo_version="$(extract_cargo_version)"
[[ -n "$cargo_version" ]] || fail "Cargo.toml is missing a [package] version"

case "$cargo_version" in
[0-9]*.[0-9]*.[0-9]*) ok "Cargo.toml version: $cargo_version" ;;
*) fail "Cargo.toml version '$cargo_version' is not semver" ;;
esac

grep -Fq 'name = "codetracer-beam-recorder"' Cargo.toml ||
  fail "Cargo.toml [package].name must be 'codetracer-beam-recorder'"
ok "Cargo.toml package name is canonical"

grep -Fq 'license = "MIT"' Cargo.toml ||
  fail "Cargo.toml [package].license must be 'MIT'"
ok "Cargo.toml declares MIT license"

grep -Fq 'repository = "' Cargo.toml ||
  fail "Cargo.toml [package].repository missing"
ok "Cargo.toml declares repository"

grep -Fq 'description = "' Cargo.toml ||
  fail "Cargo.toml [package].description missing"
ok "Cargo.toml declares description"

# ---------- 2. mix.exs metadata ----------
bold "mix.exs metadata"
[[ -f mix.exs ]] || fail "mix.exs missing"

mix_version="$(extract_mix_version)"
[[ -n "$mix_version" ]] || fail "mix.exs is missing a project version"

if [[ "$mix_version" != "$cargo_version" ]]; then
  fail "mix.exs version ($mix_version) does not match Cargo.toml ($cargo_version)"
fi
ok "mix.exs version matches Cargo.toml: $mix_version"

grep -Eq 'defp?[[:space:]]+package' mix.exs ||
  fail "mix.exs must declare a Hex package/0 function for publish metadata"
ok "mix.exs declares a Hex package/0"

grep -Fq 'description: ' mix.exs ||
  fail "mix.exs must declare a Hex description"
ok "mix.exs declares description"

grep -Fq 'licenses' mix.exs ||
  fail "mix.exs must declare licenses metadata"
ok "mix.exs declares licenses"

grep -Fq 'links' mix.exs ||
  fail "mix.exs must declare links metadata"
ok "mix.exs declares links"

# ---------- 3. rebar3 .app.src ----------
bold "rebar3_codetracer .app.src metadata"
app_src="rebar3_codetracer/src/rebar3_codetracer.app.src"
[[ -f "$app_src" ]] || fail "$app_src missing"

app_version="$(extract_app_src_version)"
[[ -n "$app_version" ]] || fail "$app_src is missing a {vsn, ...} entry"

if [[ "$app_version" != "$cargo_version" ]]; then
  fail "$app_src version ($app_version) does not match Cargo.toml ($cargo_version)"
fi
ok "$app_src vsn matches Cargo.toml: $app_version"

grep -Fq 'description' "$app_src" ||
  fail "$app_src must declare a description"
ok "$app_src declares description"

grep -Fq 'licenses' "$app_src" ||
  fail "$app_src must declare licenses"
ok "$app_src declares licenses"

# ---------- 4. CHANGELOG ----------
bold "CHANGELOG.md"
[[ -f CHANGELOG.md ]] || fail "CHANGELOG.md missing"

if ! grep -Fq "$cargo_version" CHANGELOG.md; then
  fail "CHANGELOG.md does not mention current version $cargo_version"
fi
ok "CHANGELOG.md references current version $cargo_version"

# ---------- 5. LICENSE ----------
bold "LICENSE"
[[ -f LICENSE ]] || fail "LICENSE file missing"
grep -Fq 'MIT License' LICENSE ||
  fail "LICENSE file must declare MIT License (matches Cargo.toml license = \"MIT\")"
ok "LICENSE declares MIT"

# ---------- 6. Build artifact ----------
bold "Build artifact"
if ! command -v cargo >/dev/null 2>&1; then
  fail "cargo not in PATH; run inside the dev shell (\`nix develop --command just release-check\`)"
fi

cargo build --locked --quiet 2>&1 | sed 's/^/  /'

binary=""
for candidate in target/debug/codetracer-beam-recorder target/release/codetracer-beam-recorder; do
  if [[ -x "$candidate" ]]; then
    binary="$candidate"
    break
  fi
done

[[ -n "$binary" ]] || fail "codetracer-beam-recorder binary missing under target/"
ok "binary at $binary"

# ---------- 7. CLI version consistency ----------
bold "CLI --version reports $cargo_version"
cli_version_line="$("$binary" --version)"
if ! echo "$cli_version_line" | grep -Fq "$cargo_version"; then
  fail "CLI --version output '$cli_version_line' does not contain $cargo_version"
fi
ok "$cli_version_line"

# Real downstream regression suites are run by CI through the
# workspace-locked siblings, resolved via
# scripts/resolve-sibling-rev.sh against the repo-workspaces workspace
# lock. The legacy committed sibling-pin files are forbidden by the
# canonical repo requirements (runquota/scripts/check_repo_requirements.sh),
# so release-check no longer asserts their presence.

bold "Release readiness summary"
ok "all release-check assertions held for version $cargo_version"
