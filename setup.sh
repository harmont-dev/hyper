#!/usr/bin/env bash
# One-time host provisioning for a Hyper dev/eval node. After this succeeds,
# `iex -S mix` boots a Hyper node.
#
# Provisioning mirrors docs/cookbook/install.md -- keep the two in sync, the
# same way .github/scripts/provision-kvm-host.sh is kept in lockstep with it.
#
# Deliberate deltas from install.md (this is a dev/eval path, not production):
#   - the BEAM runs as the invoking user, not a dedicated `hyper` system user
#   - PostgreSQL is a docker container (hyper-pg), --restart unless-stopped
#
# Usage: ./setup.sh           provision this host
#        ./setup.sh --check   report what is missing, change nothing
set -euo pipefail

cd "$(dirname "$0")"

WORK_DIR=/srv/hyper
PG_CONTAINER=hyper-pg
PG_IMAGE=postgres:16

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# shellcheck source=scripts/host-deps.sh
. scripts/host-deps.sh

# Each check prints nothing when satisfied, else the actionable problem.
preflight() {
  [ -e /dev/kvm ] \
    || echo "no /dev/kvm -- Hyper needs a Linux host with KVM (bare metal, or a cloud instance with nested virtualization)"
  [ "$(stat -fc %T /sys/fs/cgroup)" = cgroup2fs ] \
    || echo "cgroups v2 not mounted at /sys/fs/cgroup"
  host_pm >/dev/null \
    || echo "no supported package manager (apt, dnf, zypper, pacman) -- follow docs/cookbook/install.md"
  have sudo || [ "$(id -u)" -eq 0 ] || echo "sudo is required for host provisioning"
  have elixir \
    || echo "install Elixir ~> 1.20 on OTP 28+ first: https://elixir-lang.org/install.html"
  have rustup || echo "install Rust via rustup first: https://rustup.rs"
  if ! have docker; then
    echo "install Docker first (used only for the dev postgres): https://docs.docker.com/engine/install/"
  elif ! docker info >/dev/null 2>&1; then
    echo "docker is installed but not usable -- is the daemon running, and are you in the docker group?"
  fi
}

if [ "${1:-}" = --check ]; then
  problems="$(preflight)"
  missing_cmds="$(host_missing_cmds "${HOST_HELPER_TOOLS[@]}" "${HOST_OTHER_TOOLS[@]}")"
  missing_mods="$(host_missing_modules "${HOST_MODULES[@]}")"
  printf 'kernel:          %s\n' "$(uname -r)"
  printf 'package manager: %s\n' "$(host_pm || echo none)"
  printf 'missing tools:   %s\n' "$(echo "${missing_cmds:-none}" | xargs)"
  printf 'missing modules: %s\n' "$(echo "${missing_mods:-none}" | xargs)"
  if [ -n "$problems" ]; then
    while IFS= read -r p; do printf 'blocker:         %s\n' "$p"; done <<<"$problems"
  fi
  [ -z "$problems$missing_mods" ] || exit 1
  exit 0
fi

problems="$(preflight)"
[ -z "$problems" ] || fail "$problems"

info "host provisioning needs root -- asking sudo once up front"
[ ${#SUDO[@]} -eq 0 ] || sudo -v

info "OS packages"
host_install_deps

info "kernel modules"
host_load_modules

info "IPv4 forwarding (required — host-init only asserts it, never sets it)"
sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null
echo 'net.ipv4.ip_forward=1' \
  | sudo tee /etc/sysctl.d/99-hyper-ip-forward.conf >/dev/null

info "build toolchain extras"
rustup target add "$(uname -m)-unknown-linux-musl"
[ -x "$HOME/.mix/escripts/protoc-gen-elixir" ] \
  || mix escript.install --force hex protobuf 0.17.0

if [ -f /etc/hyper/config.toml ]; then
  info "/etc/hyper/config.toml exists -- leaving it alone"
else
  info "writing /etc/hyper/config.toml"
  # A single-uplink host NATs guest egress out of its default-route NIC.
  uplink="$(ip route show default | awk '{print $5; exit}')"
  [ -n "$uplink" ] \
    || fail "could not detect a default-route interface -- set [network] uplink in /etc/hyper/config.toml by hand (see docs/cookbook/install.md)"
  tools="$(host_tools_toml)"
  sudo mkdir -p /etc/hyper
  sudo tee /etc/hyper/config.toml >/dev/null <<EOF
work_dir = "/srv/hyper"

[tools]
firecracker = "/opt/firecracker/firecracker"
jailer = "/opt/firecracker/jailer"
${tools}

[jails]
uid_gid_range = [900000, 999999]
cgroup = "hyper"

[network]
uplink = "${uplink}"
clone_pool = "172.31.0.0/16"
resolver = "1.1.1.1"
EOF
  sudo chown root:root /etc/hyper/config.toml
  sudo chmod 0644 /etc/hyper/config.toml
fi

info "cgroup subtree"
sudo mkdir -p /sys/fs/cgroup/hyper
echo '+cpu +memory' \
  | sudo tee /sys/fs/cgroup/hyper/cgroup.subtree_control >/dev/null
echo 'd /sys/fs/cgroup/hyper 0755 root root -' \
  | sudo tee /etc/tmpfiles.d/hyper-cgroup.conf >/dev/null

info "work dir ($WORK_DIR)"
sudo mkdir -p "$WORK_DIR"
sudo chown "$(id -u):$(id -g)" "$WORK_DIR"
# layers/ must pre-exist: boot validation (Layer.Repo.test_system) checks
# it, and the node only creates it lazily on first image load.
mkdir -p "$WORK_DIR/layers"

info "compiling hyper (first run builds two Rust crates -- takes a while)"
mix deps.get
mix compile

info "firecracker + jailer"
sudo mkdir -p /opt/firecracker
# -R so a re-run can overwrite binaries the previous run left root-owned (the
# chmod below hands them to root); without it mix firecracker.install's cp
# hits permission denied on the second pass.
sudo chown -R "$(id -u):$(id -g)" /opt/firecracker
mix firecracker.install
sudo chown root:root /opt/firecracker/firecracker /opt/firecracker/jailer
sudo chmod 0755 /opt/firecracker/firecracker /opt/firecracker/jailer

info "setuid helper"
mix suidhelper.install
[ -u /usr/local/bin/hyper-suidhelper ] \
  || fail "hyper-suidhelper missing or not setuid-root"

info "postgres ($PG_CONTAINER)"
pg_ready() { docker exec "$PG_CONTAINER" pg_isready -U postgres >/dev/null 2>&1; }
if ! pg_ready; then
  docker start "$PG_CONTAINER" >/dev/null 2>&1 \
    || docker run -d --restart unless-stopped --name "$PG_CONTAINER" \
      -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres \
      -e POSTGRES_DB=hyper_dev -p 5432:5432 "$PG_IMAGE" >/dev/null
  for _ in $(seq 1 60); do
    pg_ready && break
    sleep 1
  done
  pg_ready || fail "postgres ($PG_CONTAINER) not ready after 60s"
fi

info "image database"
mix ecto.create -r Hyper.Img.Db.Repo
mix ecto.migrate -r Hyper.Img.Db.Repo

info "setup complete -- boot a node with: iex -S mix"
