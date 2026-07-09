#!/usr/bin/env bash
# Provision a GitHub-hosted ubuntu runner as a single-node Firecracker host
# for the `:integration` E2E suite. Mirrors docs/cookbook/install.md; keep
# the two (and setup.sh, the dev-host equivalent) in sync. Assumes:
# passwordless sudo, repo compiled (the firecracker
# and suidhelper install tasks are mix tasks), MIX_ENV matching the test run.
#
# Deliberate CI-only deltas from install.md -- do NOT remove these in a future
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
#   - [network] is always written here (install.md presents it as an optional
#     section) since the runner's default route interface is detected fresh
#     each run and integration coverage wants egress networking exercised
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
  coreutils e2fsprogs iproute2 libc-bin lvm2 nftables skopeo thin-provisioning-tools util-linux \
  "linux-modules-extra-$(uname -r)"

# -a is load-bearing: without it modprobe reads the 2nd+ names as module
# PARAMETERS of the first, and the load fails.
#
# nf_tables + nf_nat back host-init's `hyper` nftables table and its
# masquerade/SNAT/DNAT rules. A fresh GitHub-hosted runner does not have them
# loaded, and the netfilter family does not always autoload on first `nft` use,
# so `nft add table ip hyper` fails (empty stderr, non-zero exit) and the node
# refuses to start. Load the base explicitly, as we do for the dm modules; the
# nat expression sub-modules (nft_chain_nat, nft_masq) autoload once the base is
# present and a rule is issued.
sudo modprobe -av dm_snapshot dm_thin_pool loop nf_tables nf_nat
targets="$(sudo dmsetup targets)"
echo "dmsetup targets: ${targets}"
grep -q thin-pool <<<"${targets}" || { echo "ERROR: thin-pool dm target missing" >&2; exit 1; }
command -v thin_dump >/dev/null || { echo "ERROR: thin_dump missing (thin-provisioning-tools)" >&2; exit 1; }

# Ubuntu ships thin_dump as a symlink into pdata_tools; the helper's SafeBin
# rejects symlinks, so install a dereferenced hard copy under the name the
# multi-call binary dispatches on.
sudo install -o root -g root -m 0755 "$(readlink -f "$(command -v thin_dump)")" /usr/local/sbin/thin_dump
[ ! -L /usr/local/sbin/thin_dump ] || { echo "ERROR: /usr/local/sbin/thin_dump is still a symlink" >&2; exit 1; }

# host-init (run by the node at start) asserts ip_forward=1 rather than
# setting it, so provisioning must turn it on and persist it across reboots.
sudo sysctl -w net.ipv4.ip_forward=1
echo 'net.ipv4.ip_forward=1' \
  | sudo tee /etc/sysctl.d/99-hyper-ip-forward.conf >/dev/null

# GitHub-hosted runners ship Docker, which sets the iptables `filter` FORWARD
# policy to DROP and only admits its own bridge traffic. Hyper's guest egress is
# *forwarded* (per-VM netns veth -> uplink), so Docker's drop silently eats
# every packet the guest sends — the guest configures its NIC fine but nothing
# ever returns. Admit the clone pool (172.31.0.0/16, the helper's default) both
# directions via DOCKER-USER, which Docker evaluates before its own drops; the
# `hyper` nftables forward chain still enforces guest isolation. Fall back to an
# accepting FORWARD policy on a host without Docker's chain.
clone_pool="172.31.0.0/16"
if sudo iptables -L DOCKER-USER >/dev/null 2>&1; then
  sudo iptables -I DOCKER-USER -s "${clone_pool}" -j ACCEPT
  sudo iptables -I DOCKER-USER -d "${clone_pool}" -j ACCEPT
else
  sudo iptables -P FORWARD ACCEPT
fi

# The default-route interface is the uplink guests NAT egress through.
uplink="$(ip route show default | awk '{print $5; exit}')"
[ -n "${uplink}" ] || { echo "ERROR: could not detect default-route uplink interface" >&2; exit 1; }
echo "detected uplink: ${uplink}"

sudo mkdir -p /etc/hyper
sudo tee /etc/hyper/config.toml >/dev/null <<EOF
work_dir = "/srv/hyper"

[tools]
firecracker = "/opt/firecracker/firecracker"
jailer = "/opt/firecracker/jailer"
thin_dump = "/usr/local/sbin/thin_dump"

[jails]
uid_gid_range = [900000, 999999]
cgroup = "hyper"

# The runner is a dedicated ephemeral host: the soft budget's default
# cpu_max_load (0.8) refuses VMs with :no_capacity while compile/provision
# load is still decaying, and nothing else runs here worth protecting.
[budget]
cpu_max_load = 4.0

# Enables per-VM egress NAT. The nft table itself is owned by host-init
# (created idempotently at node start), not by this script.
[network]
uplink = "${uplink}"
EOF
sudo chown root:root /etc/hyper/config.toml
sudo chmod 0644 /etc/hyper/config.toml

sudo mkdir -p /sys/fs/cgroup/hyper
echo '+cpu +memory' | sudo tee /sys/fs/cgroup/hyper/cgroup.subtree_control >/dev/null

# The BEAM (the `runner` user -- Hyper refuses to run as root) owns work_dir.
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
