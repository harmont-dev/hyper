#!/usr/bin/env bash
# Verify the suidhelper crate and the Elixir package both declare the version
# passed as $1 (the release version, WITHOUT a leading "v"). Prints every
# mismatch and exits non-zero. Used by the release workflow's version guard and
# runnable locally before tagging:  bash .github/scripts/check-versions.sh 0.2.0
set -euo pipefail

want="${1:?usage: check-versions.sh <version-without-v>}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

cargo_ver="$(grep -m1 '^version = ' "$root/native/suidhelper/Cargo.toml" | sed -E 's/.*"([^"]+)".*/\1/')"
mix_ver="$(grep -m1 'version: "' "$root/mix.exs" | sed -E 's/.*version: "([^"]+)".*/\1/')"

status=0
if [ "$cargo_ver" != "$want" ]; then
  echo "::error::Cargo.toml version is $cargo_ver but release is $want" >&2
  status=1
fi
if [ "$mix_ver" != "$want" ]; then
  echo "::error::mix.exs version is $mix_ver but release is $want" >&2
  status=1
fi
if [ "$status" -eq 0 ]; then
  echo "OK: Cargo.toml and mix.exs both at $want"
fi
exit "$status"
