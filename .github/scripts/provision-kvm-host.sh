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
#   - the 2001:db8::/64 fallback for [net] ipv6_prefix (install.md has the
#     operator use the uplink's real prefix; the runner has no global IPv6)
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
  coreutils e2fsprogs libc-bin lvm2 nftables skopeo thin-provisioning-tools util-linux

modules_extra="linux-modules-extra-$(uname -r)"
if apt-cache show "${modules_extra}" >/dev/null 2>&1; then
  sudo apt-get install -y "${modules_extra}"
else
  echo "${modules_extra} is not available; relying on the kernel's base modules"
fi

# -a is load-bearing: without it modprobe reads the 2nd+ names as module
# PARAMETERS of the first, and the load fails.
sudo modprobe -av dm_snapshot dm_thin_pool loop
targets="$(sudo dmsetup targets)"
echo "dmsetup targets: ${targets}"
grep -q thin-pool <<<"${targets}" || { echo "ERROR: thin-pool dm target missing" >&2; exit 1; }
command -v thin_dump >/dev/null || { echo "ERROR: thin_dump missing (thin-provisioning-tools)" >&2; exit 1; }

# Ubuntu ships thin_dump as a symlink into pdata_tools; the helper's SafeBin
# rejects symlinks, so install a dereferenced hard copy under the name the
# multi-call binary dispatches on.
sudo install -o root -g root -m 0755 "$(readlink -f "$(command -v thin_dump)")" /usr/local/sbin/thin_dump
[ ! -L /usr/local/sbin/thin_dump ] || { echo "ERROR: /usr/local/sbin/thin_dump is still a symlink" >&2; exit 1; }

uplink="$(ip -o route show default | awk '{print $5; exit}')"
[ -n "${uplink}" ] || { echo "ERROR: no default route to take the uplink from" >&2; exit 1; }

# Proxy NDP only answers inside the prefix that is on-link at the uplink, so that
# prefix is the one VMs draw from: the network of the uplink's global, stable,
# non-ULA address. Several candidates, or one whose address already sits in
# <prefix>:1::/80 where VMs live, need an operator to choose.
ipv6_prefix="$(ip -6 -o addr show dev "${uplink}" scope global | python3 -c '
import ipaddress, sys

ula = ipaddress.ip_network("fc00::/7")
found = {}
for line in sys.stdin:
    fields = line.split()
    if "inet6" not in fields or "temporary" in fields or "deprecated" in fields:
        continue
    iface = ipaddress.ip_interface(fields[fields.index("inet6") + 1])
    if iface.ip not in ula:
        found.setdefault(iface.network, iface.ip)

if len(found) > 1:
    sys.exit("ERROR: several IPv6 prefixes on the uplink; set [net] ipv6_prefix by hand: "
             + ", ".join(map(str, found)))
for net, addr in found.items():
    if net.prefixlen > 64:
        sys.exit(f"ERROR: the uplink prefix {net} is longer than /64; set [net] ipv6_prefix by hand")
    vms = ipaddress.ip_network((int(net.network_address) | 1 << 48, 80))
    if addr in vms:
        sys.exit(f"ERROR: the uplink address {addr} sits in {vms}, the VM range")
    print(net)
')"
# The runner has no global IPv6, so VMs get a documentation-range prefix: guest
# IPv6 is unreachable from outside, but outbound IPv4 through the NATs works.
ipv6_prefix="${ipv6_prefix:-2001:db8::/64}"
# New veth and tap devices take their IPv6 setting from conf/default; every VM link
# carries IPv6 link-local addresses, so it must be on.
sudo sysctl -qw net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0

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

[net]
uplink = "${uplink}"
ipv6_prefix = "${ipv6_prefix}"

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
