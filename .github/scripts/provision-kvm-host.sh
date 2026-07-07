#!/usr/bin/env bash
# Provision a GitHub-hosted ubuntu runner as a single-node Firecracker host
# for the `:integration` E2E suite. Mirrors docs/cookbook/install.md; keep
# the two in sync. Assumes: passwordless sudo, repo compiled (the firecracker
# and suidhelper install tasks are mix tasks), MIX_ENV matching the test run.
#
# Deliberate CI-only deltas from install.md — do NOT remove these in a future
# sync pass:
#   - the 0666 udev kvm rule (install.md assumes a real host with a `kvm`
#     group an operator is added to; the ephemeral runner has neither)
#   - the `[budget]` stanza raising cpu_max_load to 4.0 (this host is a
#     dedicated ephemeral runner, so the default's contention guard against
#     other workloads doesn't apply, and compile/provision load would
#     otherwise trip :no_capacity)
#   - pre-creating /srv/hyper/layers (install.md documents this too, but it's
#     load-bearing here since nothing else primes it before the suite boots
#     the node)
#   - DEBIAN_FRONTEND=noninteractive (install.md is written for an interactive
#     operator session; CI has no tty to prompt on)
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# The jailed VM uid (900000+) opens /dev/kvm; 0666 is GitHub's own documented
# rule for KVM access on hosted runners.
echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' \
  | sudo tee /etc/udev/rules.d/99-kvm4all.rules >/dev/null
sudo udevadm control --reload-rules
sudo udevadm trigger --name-match=kvm

sudo apt-get update
sudo apt-get install -y \
  coreutils e2fsprogs libc-bin lvm2 skopeo util-linux \
  "linux-modules-extra-$(uname -r)"

# -a is load-bearing: without it modprobe reads the 2nd+ names as module
# PARAMETERS of the first, and the load fails.
sudo modprobe -av dm_snapshot dm_thin_pool loop
targets="$(sudo dmsetup targets)"
echo "dmsetup targets: ${targets}"
grep -q thin-pool <<<"${targets}" || { echo "ERROR: thin-pool dm target missing" >&2; exit 1; }

sudo mkdir -p /etc/hyper
sudo tee /etc/hyper/config.toml >/dev/null <<'EOF'
work_dir = "/srv/hyper"

[tools]
firecracker = "/opt/firecracker/firecracker"
jailer = "/opt/firecracker/jailer"

[jails]
uid_gid_range = [900000, 999999]
cgroup = "hyper"

# The runner is a dedicated ephemeral host: the soft budget's default
# cpu_max_load (0.8) refuses VMs with :no_capacity while compile/provision
# load is still decaying, and nothing else runs here worth protecting.
[budget]
cpu_max_load = 4.0
EOF
sudo chown root:root /etc/hyper/config.toml
sudo chmod 0644 /etc/hyper/config.toml

sudo mkdir -p /sys/fs/cgroup/hyper
echo '+cpu +memory' | sudo tee /sys/fs/cgroup/hyper/cgroup.subtree_control >/dev/null

# The BEAM (the `runner` user — Hyper refuses to run as root) owns work_dir.
# layers/ must pre-exist: boot validation (Layer.Repo.test_system) checks it,
# and the node only creates it lazily on first image load.
sudo mkdir -p /srv/hyper
sudo chown "$(id -u):$(id -g)" /srv/hyper
mkdir -p /srv/hyper/layers

# firecracker.install writes into /opt/firecracker as the invoking user, then
# the helper requires both binaries root-owned and not group/world-writable.
sudo mkdir -p /opt/firecracker
sudo chown "$(id -u)" /opt/firecracker
mix firecracker.install
sudo chown root:root /opt/firecracker/firecracker /opt/firecracker/jailer
sudo chmod 0755 /opt/firecracker/firecracker /opt/firecracker/jailer

# With passwordless sudo the task installs setuid-root itself.
mix suidhelper.install
[ -u /usr/local/bin/hyper-suidhelper ] || { echo "ERROR: hyper-suidhelper missing or not setuid-root" >&2; exit 1; }

echo "provisioned: kvm=$(ls -l /dev/kvm)"
