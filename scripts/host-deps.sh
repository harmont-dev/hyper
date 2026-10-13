# shellcheck shell=bash
# Distro-neutral host dependency resolution, sourced by setup.sh and
# .github/scripts/provision-kvm-host.sh. Every requirement is a capability --
# a command on PATH or a loadable kernel module -- and a package is installed
# only when its capability is missing, so hosts that already have a tool (from
# any source, any custom kernel) are never asked to install anything.
#
# Supported package managers: apt (Debian/Ubuntu/Pop!_OS/Mint), dnf
# (Fedora/RHEL/Rocky/Alma), zypper (openSUSE/SLES), pacman (Arch/Manjaro).
#
# Callers must run under `set -euo pipefail` and define `fail` and `info`.

# Commands the suidhelper execs. Each must resolve to a real root-owned file
# whose basename is the tool name: the helper's SafeBin refuses symlinks, so
# resolve_tool canonicalises these into the [tools] table of config.toml.
HOST_HELPER_TOOLS=(dmsetup losetup blockdev ip nft sysctl thin_dump)

# Everything else the node or provisioning needs on PATH.
HOST_OTHER_TOOLS=(skopeo mke2fs getent modinfo modprobe protoc)

# nf_tables + nf_nat back host-init's `hyper` nftables table and its NAT
# rules. The netfilter family does not always autoload on first `nft` use (a
# fresh GitHub runner fails `nft add table ip hyper` with empty stderr), so
# load the base explicitly; the nat expression sub-modules autoload from it.
HOST_MODULES=(dm_snapshot dm_thin_pool loop nf_tables nf_nat)

if [ "$(id -u)" -eq 0 ]; then SUDO=(); else SUDO=(sudo); fi

host_pm() {
  local pm
  for pm in apt-get dnf zypper pacman; do
    if command -v "$pm" >/dev/null 2>&1; then
      echo "${pm%-get}"
      return
    fi
  done
  return 1
}

# The package providing command $2 under package manager $1. The `protoc`
# package on RHEL-likes lives in CRB/PowerTools; host_install enables it.
host_pkg_for() {
  case "$1:$2" in
    *:losetup | *:blockdev) echo util-linux ;;
    *:nft) echo nftables ;;
    *:skopeo) echo skopeo ;;
    *:mke2fs) echo e2fsprogs ;;
    *:modinfo | *:modprobe) echo kmod ;;

    apt:dmsetup) echo dmsetup ;;
    apt:ip) echo iproute2 ;;
    apt:sysctl) echo procps ;;
    apt:thin_dump) echo thin-provisioning-tools ;;
    apt:getent) echo libc-bin ;;
    apt:protoc) echo protobuf-compiler ;;

    dnf:dmsetup) echo device-mapper ;;
    dnf:ip) echo iproute ;;
    dnf:sysctl) echo procps-ng ;;
    dnf:thin_dump) echo device-mapper-persistent-data ;;
    dnf:getent) echo glibc-common ;;
    dnf:protoc) echo protobuf-compiler ;;

    zypper:dmsetup) echo device-mapper ;;
    zypper:ip) echo iproute2 ;;
    zypper:sysctl) echo procps ;;
    zypper:thin_dump) echo thin-provisioning-tools ;;
    zypper:getent) echo glibc ;;
    zypper:protoc) echo protobuf-devel ;;

    pacman:dmsetup) echo device-mapper ;;
    pacman:ip) echo iproute2 ;;
    pacman:sysctl) echo procps-ng ;;
    pacman:thin_dump) echo thin-provisioning-tools ;;
    pacman:getent) echo glibc ;;
    pacman:protoc) echo protobuf ;;

    *) return 1 ;;
  esac
}

# Distros split rarely-used modules (dm-thin on cloud kernels) into a separate
# package named after the running kernel. Absent for distros without the split
# and for custom kernels (#88), which is why it is never installed blindly.
host_kernel_extra_pkg() {
  case "$1" in
    apt) echo "linux-modules-extra-$(uname -r)" ;;
    dnf) echo "kernel-modules-extra-$(uname -r)" ;;
    *) return 1 ;;
  esac
}

host_pkg_available() {
  case "$1" in
    apt) apt-cache show "$2" >/dev/null 2>&1 ;;
    dnf) dnf -q list --available "$2" >/dev/null 2>&1 ;;
    zypper) zypper -n -q search -x "$2" >/dev/null 2>&1 ;;
    pacman) pacman -Si "$2" >/dev/null 2>&1 ;;
  esac
}

host_refresh() {
  case "$1" in
    apt) "${SUDO[@]}" apt-get update ;;
    dnf) ;;
    zypper) "${SUDO[@]}" zypper -n refresh ;;
    # Never -Sy: syncing the database without upgrading is an unsupported
    # partial upgrade on Arch. A stale database surfaces as a download error.
    pacman) ;;
  esac
}

host_enable_crb() {
  command -v dnf >/dev/null 2>&1 || return 0
  # Fedora has no CRB and ships protobuf-compiler in its main repo.
  grep -qE '^ID_LIKE=.*(rhel|centos)' /etc/os-release 2>/dev/null || return 0
  "${SUDO[@]}" dnf -y install dnf-plugins-core >/dev/null
  "${SUDO[@]}" dnf config-manager --set-enabled crb 2>/dev/null \
    || "${SUDO[@]}" dnf config-manager --set-enabled powertools
}

host_install() {
  local pm=$1
  shift
  [ $# -gt 0 ] || return 0
  case "$pm" in
    apt) "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
    dnf)
      if printf '%s\n' "$@" | grep -qx protobuf-compiler; then host_enable_crb; fi
      "${SUDO[@]}" dnf -y install "$@"
      ;;
    zypper) "${SUDO[@]}" zypper -n install "$@" ;;
    pacman) "${SUDO[@]}" pacman -S --needed --noconfirm "$@" ;;
  esac
}

# Commands from $@ not found on PATH. sbin dirs are searched explicitly since
# a non-root user's PATH often omits them.
host_missing_cmds() {
  local cmd
  for cmd in "$@"; do
    PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin" command -v "$cmd" >/dev/null 2>&1 \
      || echo "$cmd"
  done
}

host_missing_modules() {
  local mod
  for mod in "$@"; do
    # modinfo also resolves built-ins (e.g. loop on many kernels).
    PATH="$PATH:/usr/sbin:/sbin" modinfo "$mod" >/dev/null 2>&1 || echo "$mod"
  done
}

host_pm_or_fail() {
  host_pm \
    || fail "no supported package manager (apt, dnf, zypper, pacman) -- install the tools listed in docs/cookbook/install.md by hand"
}

# Install the packages providing every missing command.
host_install_packages() {
  local pm cmd pkg
  local -a missing pkgs=()
  pm="$(host_pm_or_fail)"

  info "package manager: $pm"
  host_refresh "$pm"

  mapfile -t missing < <(host_missing_cmds "${HOST_HELPER_TOOLS[@]}" "${HOST_OTHER_TOOLS[@]}")
  for cmd in "${missing[@]}"; do
    pkg="$(host_pkg_for "$pm" "$cmd")" || fail "no known $pm package provides $cmd"
    printf '%s\n' "${pkgs[@]}" | grep -qx "$pkg" || pkgs+=("$pkg")
  done
  if [ ${#pkgs[@]} -gt 0 ]; then
    info "installing: ${pkgs[*]}"
    host_install "$pm" "${pkgs[@]}"
  fi

  mapfile -t missing < <(host_missing_cmds "${HOST_HELPER_TOOLS[@]}" "${HOST_OTHER_TOOLS[@]}")
  [ ${#missing[@]} -eq 0 ] || fail "still missing after install: ${missing[*]}"
}

# Make every module in HOST_MODULES loadable, pulling in the kernel's split
# extra-modules package only when the running kernel lacks one and has it.
host_ensure_modules() {
  local pm pkg
  local -a mods
  pm="$(host_pm_or_fail)"

  mapfile -t mods < <(host_missing_modules "${HOST_MODULES[@]}")
  [ ${#mods[@]} -gt 0 ] || return 0
  [ -d "/lib/modules/$(uname -r)" ] \
    || fail "no modules for the running kernel $(uname -r) -- the kernel was likely upgraded; reboot into it and re-run"
  if pkg="$(host_kernel_extra_pkg "$pm")" && host_pkg_available "$pm" "$pkg"; then
    info "kernel lacks ${mods[*]}; installing $pkg"
    host_install "$pm" "$pkg"
    mapfile -t mods < <(host_missing_modules "${HOST_MODULES[@]}")
  fi
  [ ${#mods[@]} -eq 0 ] \
    || fail "kernel $(uname -r) does not provide ${mods[*]} -- Hyper needs device-mapper thin provisioning and nftables NAT; boot a kernel built with them"
}

host_install_deps() {
  host_install_packages
  host_ensure_modules
}

host_load_modules() {
  # -a is load-bearing: without it modprobe reads the 2nd+ names as module
  # PARAMETERS of the first, and the load fails.
  "${SUDO[@]}" modprobe -av "${HOST_MODULES[@]}"
  printf '%s\n' "${HOST_MODULES[@]}" \
    | "${SUDO[@]}" tee /etc/modules-load.d/hyper.conf >/dev/null
  "${SUDO[@]}" dmsetup targets | grep -q thin-pool \
    || fail "thin-pool dm target missing after modprobe"
}

# Print a path to tool $1 that SafeBin accepts. Distros ship some tools as
# symlinks into multi-call binaries (thin_dump -> pdata_tools everywhere);
# those get a dereferenced root-owned copy in /usr/local/sbin under the name
# the binary dispatches on.
resolve_tool() {
  local name=$1 found real
  found="$(PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin" command -v "$name")" \
    || fail "$name not found"
  real="$(readlink -f "$found")"
  if [ "$(basename "$real")" = "$name" ]; then
    echo "$real"
  else
    "${SUDO[@]}" install -o root -g root -m 0755 "$real" "/usr/local/sbin/$name"
    echo "/usr/local/sbin/$name"
  fi
}

# The [tools] lines for every helper tool, plus the node tools whose sbin home
# (mke2fs on openSUSE/Fedora) is often off the BEAM user's PATH.
host_tools_toml() {
  local tool
  for tool in "${HOST_HELPER_TOOLS[@]}" skopeo mke2fs; do
    printf '%s = "%s"\n' "$tool" "$(resolve_tool "$tool")"
  done
}
