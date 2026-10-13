#!/usr/bin/env bash
# Run as root inside a distro container (see ci.yml `host-deps`): installs the
# userland packages scripts/host-deps.sh maps for this distro's package manager,
# then asserts every [tools] path it would write passes the suidhelper's SafeBin
# checks -- absolute, exact basename, a regular non-symlink file, root-owned,
# not group/other-writable. Kernel modules belong to the host kernel, not the
# container, so they are covered by the KVM integration job instead.
set -euo pipefail

info() { echo "==> $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

# shellcheck source=scripts/host-deps.sh
. "$(dirname "$0")/../../scripts/host-deps.sh"

# A throwaway container's empty sync database is the one place a bare -Sy is fine.
if [ "$(host_pm_or_fail)" = pacman ]; then pacman -Sy --noconfirm; fi

host_install_packages

while IFS= read -r line; do
  name="${line%% = *}"
  path="${line#*= \"}"
  path="${path%\"}"
  [ "${path#/}" != "$path" ] || fail "$name: $path is not absolute"
  [ "$(basename "$path")" = "$name" ] || fail "$name: basename of $path"
  [ -f "$path" ] && [ ! -L "$path" ] || fail "$name: $path is not a regular file"
  [ "$(stat -c %u "$path")" = 0 ] || fail "$name: $path not root-owned"
  [ $(( 0$(stat -c %a "$path") & 022 )) -eq 0 ] || fail "$name: $path is group/other-writable"
  echo "ok  $line"
done < <(host_tools_toml)
