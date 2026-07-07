#!/usr/bin/env bash
# Provision a GitHub-hosted ubuntu runner as a single-node Firecracker host
# for the `:integration` E2E suite. Mirrors docs/cookbook/install.md; keep
# the two in sync. Assumes: passwordless sudo, repo compiled (the firecracker
# and suidhelper install tasks are mix tasks), MIX_ENV matching the test run.
set -euo pipefail

# The jailed VM uid (900000+) opens /dev/kvm; 0666 is GitHub's own documented
# rule for KVM access on hosted runners.
echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' \
  | sudo tee /etc/udev/rules.d/99-kvm4all.rules
sudo udevadm control --reload-rules
sudo udevadm trigger --name-match=kvm

sudo apt-get update
sudo apt-get install -y \
  coreutils e2fsprogs libc-bin lvm2 skopeo util-linux \
  "linux-modules-extra-$(uname -r)"

sudo modprobe dm_snapshot dm_thin_pool loop
sudo dmsetup targets | grep -q thin-pool

sudo mkdir -p /etc/hyper
sudo tee /etc/hyper/config.toml >/dev/null <<'EOF'
work_dir = "/srv/hyper"

[tools]
firecracker = "/opt/firecracker/firecracker"
jailer = "/opt/firecracker/jailer"

[jails]
uid_gid_range = [900000, 999999]
cgroup = "hyper"
EOF
sudo chown root:root /etc/hyper/config.toml
sudo chmod 0644 /etc/hyper/config.toml

sudo mkdir -p /sys/fs/cgroup/hyper
echo '+cpu +memory' | sudo tee /sys/fs/cgroup/hyper/cgroup.subtree_control

# The BEAM (the `runner` user — Hyper refuses to run as root) owns work_dir.
sudo mkdir -p /srv/hyper
sudo chown "$(id -u):$(id -g)" /srv/hyper

# firecracker.install writes into /opt/firecracker as the invoking user, then
# the helper requires both binaries root-owned and not group/world-writable.
sudo mkdir -p /opt/firecracker
sudo chown "$(id -u)" /opt/firecracker
mix firecracker.install
sudo chown root:root /opt/firecracker/firecracker /opt/firecracker/jailer
sudo chmod 0755 /opt/firecracker/firecracker /opt/firecracker/jailer

# With passwordless sudo the task installs setuid-root itself.
mix suidhelper.install
[ -u /usr/local/bin/hyper-suidhelper ]

echo "provisioned: kvm=$(ls -l /dev/kvm)"
