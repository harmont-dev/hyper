#!/usr/bin/env bash
# One-time host provisioning for a Hyper dev/eval node. After this succeeds,
# `iex -S mix` boots a Hyper node (or `foreman start` — see Procfile).
#
# Provisioning mirrors docs/cookbook/install.md — keep the two in sync, the
# same way .github/scripts/provision-kvm-host.sh is kept in lockstep with it.
#
# Deliberate deltas from install.md (this is a dev/eval path, not production):
#   - the BEAM runs as the invoking user, not a dedicated `hyper` system user
#   - PostgreSQL is a docker container (hyper-pg), --restart unless-stopped
set -euo pipefail

cd "$(dirname "$0")"

WORK_DIR=/srv/hyper
PG_CONTAINER=hyper-pg
PG_IMAGE=postgres:16

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ -e /dev/kvm ] \
  || fail "no /dev/kvm — Hyper needs a Linux host with KVM (bare metal, or a cloud instance with nested virtualization)"
[ "$(stat -fc %T /sys/fs/cgroup)" = cgroup2fs ] \
  || fail "cgroups v2 not mounted at /sys/fs/cgroup"
have apt-get \
  || fail "setup.sh automates Ubuntu/Debian only — follow docs/cookbook/install.md on other distros"
have sudo || fail "sudo is required for host provisioning"
have elixir \
  || fail "install Elixir ~> 1.20 on OTP 28+ first: https://elixir-lang.org/install.html"
have rustup || fail "install Rust via rustup first: https://rustup.rs"
have docker \
  || fail "install Docker first (used only for the dev postgres): https://docs.docker.com/engine/install/"
docker info >/dev/null 2>&1 \
  || fail "docker is installed but not usable — is the daemon running, and are you in the docker group?"

info "host provisioning needs root — asking sudo once up front"
sudo -v

info "OS packages"
sudo apt-get update
sudo apt-get install -y \
  coreutils e2fsprogs libc-bin lvm2 skopeo thin-provisioning-tools \
  util-linux "linux-modules-extra-$(uname -r)"

info "device-mapper modules"
# -a is load-bearing: without it modprobe reads the 2nd+ names as module
# PARAMETERS of the first, and the load fails.
sudo modprobe -av dm_snapshot dm_thin_pool loop
printf 'dm_snapshot\ndm_thin_pool\nloop\n' \
  | sudo tee /etc/modules-load.d/hyper.conf >/dev/null
sudo dmsetup targets | grep -q thin-pool \
  || fail "thin-pool dm target missing after modprobe"

# Ubuntu ships thin_dump as a symlink into pdata_tools; the helper's SafeBin
# rejects symlinks, so install a dereferenced hard copy under the name the
# multi-call binary dispatches on.
sudo install -o root -g root -m 0755 \
  "$(readlink -f "$(command -v thin_dump)")" /usr/local/sbin/thin_dump

info "build toolchain extras"
rustup target add "$(uname -m)-unknown-linux-musl"
have protoc || sudo apt-get install -y protobuf-compiler
[ -x "$HOME/.mix/escripts/protoc-gen-elixir" ] \
  || mix escript.install --force hex protobuf 0.17.0

if [ -f /etc/hyper/config.toml ]; then
  info "/etc/hyper/config.toml exists — leaving it alone"
else
  info "writing /etc/hyper/config.toml"
  sudo mkdir -p /etc/hyper
  sudo tee /etc/hyper/config.toml >/dev/null <<'EOF'
work_dir = "/srv/hyper"

[tools]
firecracker = "/opt/firecracker/firecracker"
jailer = "/opt/firecracker/jailer"
thin_dump = "/usr/local/sbin/thin_dump"

[jails]
uid_gid_range = [900000, 999999]
cgroup = "hyper"
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

info "compiling hyper (first run builds two Rust crates — takes a while)"
mix deps.get
mix compile

info "firecracker + jailer"
sudo mkdir -p /opt/firecracker
sudo chown "$(id -u)" /opt/firecracker
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

info "setup complete — boot a node with: iex -S mix"
