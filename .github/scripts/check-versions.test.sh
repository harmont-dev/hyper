#!/usr/bin/env bash
# Plain-bash test for check-versions.sh (no external test framework).
# Derives the "matching" version from mix.exs so it tracks the repo as it bumps.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/check-versions.sh"
root="$(cd "$here/../.." && pwd)"
fails=0

real="$(grep -m1 'version: "' "$root/mix.exs" | sed -E 's/.*version: "([^"]+)".*/\1/')"

# 1. Matching version -> exit 0
if bash "$script" "$real" >/dev/null 2>&1; then
  echo "ok 1 - matching version passes"
else
  echo "not ok 1 - matching version ($real) should pass"; fails=1
fi

# 2. Mismatched version -> non-zero
if bash "$script" "99.99.99" >/dev/null 2>&1; then
  echo "not ok 2 - mismatched version should fail"; fails=1
else
  echo "ok 2 - mismatched version fails"
fi

# 3. Missing argument -> non-zero
if bash "$script" >/dev/null 2>&1; then
  echo "not ok 3 - missing argument should fail"; fails=1
else
  echo "ok 3 - missing argument fails"
fi

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; fi
exit "$fails"
