#!/usr/bin/env bash
# Fetch the Hex dependencies the RS-M8 web demos need.
#
# `test-programs/elixir/plug_web` and `test-programs/elixir/phoenix_web` are
# recorded against the real Plug/Cowboy and Phoenix packages -- that is the
# point of them, and the reason the older `plug_smoke` fixture (which
# hand-rolls HTTP over :gen_tcp so it needs nothing from Hex) is kept
# alongside rather than replaced.
#
# Fetching happens here, once, rather than inside the ExUnit suites, so that a
# transient Hex failure is reported as "dependencies could not be fetched"
# instead of as a test failure, and so the suites themselves never touch the
# network. The suites fail loudly if `deps/` is missing; they never skip.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fixtures=(
  "$repo_root/test-programs/elixir/plug_web"
  "$repo_root/test-programs/elixir/phoenix_web"
)

for fixture in "${fixtures[@]}"; do
  if [[ ! -f "$fixture/mix.exs" ]]; then
    echo "FAIL: expected a mix project at $fixture" >&2
    exit 1
  fi

  echo "[prepare-web-fixtures] mix deps.get in $fixture"
  (cd "$fixture" && env MIX_ENV=test mix deps.get)
done

echo "PASS: RS-M8 web fixture dependencies are present"
