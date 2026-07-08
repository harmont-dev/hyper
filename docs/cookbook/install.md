# Quick Start

This document provides the quickest start available to get Hyper running.

## Configuration

Before you can use `Hyper`, you must do a large amount of configuration. The
following guide must be applied on all nodes you run `Hyper` on.

Before proceeding, ensure you meet all of these hard requirements:

| Requirement | Test |
|-------------|------|
| [KVM](https://linux-kvm.org/page/Main_Page) available | `stat /dev/kvm` returns zero. |
| You have root access through `sudo`. | - |
| Your machine has cgroups V2 | `stat -fc %T /sys/fs/cgroup` returns zero. |

### OS Packages

<!-- tabs-open -->

### Ubuntu

You can install the required packages by running:

```sh
sudo apt update && sudo apt install -y \
  coreutils \
  e2fsprogs \
  libc-bin \
  linux-modules-extra-$(uname -r) \
  lvm2 \
  skopeo \
  thin-provisioning-tools \
  util-linux
```

### Rocky

You can install the required packages by running:

```sh
sudo dnf install -y \
  coreutils \
  device-mapper-persistent-data \
  e2fsprogs \ 
  glibc-common \
  kernel-modules-extra-$(uname -r) \
  lvm2 \
  skopeo \
  util-linux
```

> #### Untested {: .warning}
>
> Rocky has not been tested, but should work.

> #### `thin_dump` {: .info}
>
> `thin-provisioning-tools` (`device-mapper-persistent-data` on Rocky) provides
> `thin_dump`, which fork publish requires to read a thin snapshot's
> provisioned ranges straight from the pool's metadata. Without it,
> `Hyper.Vm.fork/1`'s cross-node path fails; same-node `fast_fork/1` is
> unaffected.

<!-- tabs-close -->

### Build Toolchain

Hyper compiles two Rust components as part of `mix compile` — the setuid
helper and the in-guest agent — and generates its Firecracker/gRPC bindings
from the shipped specs. Every machine that **compiles** Hyper (including as a
Mix dependency) therefore needs, besides Elixir `~> 1.20` on OTP 28+:

```sh
# Rust via rustup (the helper pins its toolchain via rust-toolchain.toml,
# which rustup auto-installs on first build), plus the static musl target
# for the guest agent:
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
rustup target add "$(uname -m)-unknown-linux-musl"

# protoc + the protoc-gen-elixir plugin, for the generated gRPC bindings:
sudo apt install -y protobuf-compiler   # dnf install protobuf-compiler
mix escript.install hex protobuf 0.17.0
```

`~/.mix/escripts` does not need to be on your `PATH` — the build finds
`protoc-gen-elixir` there itself.

### Device Mapper Config

Hyper relies on `dm-snapshot` and `dm-thin` to build COW filesystems. Load the
modules and confirm the targets are present:

```sh
sudo modprobe -a dm_snapshot dm_thin_pool loop
sudo dmsetup targets # must list snapshot, thin, and thin-pool
```

> #### Persistent Config {: .warning}
>
> Loading modules via `modprobe` is ephemeral and will be reset on next boot.
> To make your config persistent:
>
> ```sh
> printf 'dm_snapshot\ndm_thin_pool\nloop\n' \
>     | sudo tee /etc/modules-load.d/hyper.conf
> ```

### PostgreSQL

Hyper needs a **PostgreSQL** server reachable from every node - it is the image
database and the only stateful external dependency.

For local development the quickest path is Docker. The connection details below
match the defaults in `config/config.exs` (`Hyper.Img.Db.Repo`):

```sh
docker run -d --name hyper-pg \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=hyper_dev \
  -p 5432:5432 \
  postgres:16
```

> #### Persistence {: .warning}
>
> Note that the example container should not be used in production -- it will
> be deleted on boot.
>
> We highly suggest you get a managed PostgresSQL instance. The following
> commonly used options are available:
>
>   - [AWS RDS](https://aws.amazon.com/rds/postgresql/) if you're in the AWS
>     ecosystem.
>   - [GCP CloudSQL](https://cloud.google.com/sql) if you're in the GCP
>     ecosystem.
>
> The author uses GCP.

### Configuration

It is mandatory that you create an `/etc/hyper/config.toml` file on every node.
A reasonable starting point is:

```toml
# The working directory for hyper. Hyper will create a directory tree in this
# directory and running images, sockets and scratch space will be created in
# this directory. We **strongly** encourage this be mounted on an NVMe drive.
work_dir = "/srv/hyper"

# Paths to every external binary hyper uses. All paths must be absolute.
#
# The privileged binaries the setuid helper runs (firecracker, jailer, dmsetup,
# losetup, blockdev) must be root-owned and not group/world writable -- the
# helper refuses them otherwise. The node-run tools (skopeo, umoci, mke2fs) have
# no such requirement.
[tools]
# **required**. basename **must** be 'firecracker'.
firecracker = "/opt/firecracker/firecracker"

# **required**. basename **must** be 'jailer'.
jailer = "/opt/firecracker/jailer"

# optional -- privileged device tools, default to /usr/sbin/<name>.
# dmsetup  = "/usr/sbin/dmsetup"
# losetup  = "/usr/sbin/losetup"
# blockdev = "/usr/sbin/blockdev"

# optional -- node-run tools. skopeo/mke2fs default to the name on PATH; omit
# umoci to let hyper download and cache a pinned release.
# skopeo     = "skopeo"
# mke2fs     = "mke2fs"
# umoci      = "/usr/bin/umoci"
# suidhelper = "/usr/local/bin/hyper-suidhelper"

[jails]
# The valid range of user/group IDs in which new VMs will be spawned. Hyper
# will create new VM jails for each VM within the given range.
uid_gid_range = [900000, 999999]
# optional
cgroup = "hyper"
```

> #### Security {: .error}
>
> This file **must** be owned by `root`, not group and not world writable.
> `Hyper` will refuse to boot otherwise.

For more details on configuring and tuning Hyper, we suggest you see the
[configuration guide](config.md).

### VM Networking (required)

VM networking is **mandatory**: a node refuses to start without a `[network]`
table in `/etc/hyper/config.toml`, and every VM gets NAT'd egress out through a
physical interface on the host. There is no opt-out — a node that fails this
preflight will not boot (`{:error, :network_not_configured}`, a missing uplink,
or IPv4 forwarding off). The `hyper` nft table itself is created (and owned) by
`host-init`, which runs automatically at node start — you never create nft rules
by hand. You must prepare the host first:

Install `iproute2` and `nftables`:

```sh
sudo apt install -y iproute2 nftables   # dnf install -y iproute nftables
```

Enable IPv4 forwarding. `host-init` only *asserts* this is on — it refuses to
proceed rather than setting it for you:

```sh
sudo sysctl -w net.ipv4.ip_forward=1
```

> #### Persistent Config {: .warning}
>
> Loading this via `sysctl -w` is ephemeral and resets on reboot. Persist it:
>
> ```sh
> echo 'net.ipv4.ip_forward=1' \
>     | sudo tee /etc/sysctl.d/99-hyper-ip-forward.conf
> ```

> #### Conflicting FORWARD firewall {: .warning}
>
> Guest egress is *forwarded* (per-VM netns veth → uplink). If the host already
> runs a firewall that defaults the `filter` FORWARD chain to DROP — Docker does
> this, and so do some hardened base images — those drops silently eat every
> guest packet: the guest configures its NIC correctly but nothing ever returns.
> Admit the clone pool through the firewall's user hook (Docker evaluates
> `DOCKER-USER` before its own drops); the `hyper` nft forward chain still
> enforces guest isolation:
>
> ```sh
> sudo iptables -I DOCKER-USER -s 172.31.0.0/16 -j ACCEPT
> sudo iptables -I DOCKER-USER -d 172.31.0.0/16 -j ACCEPT
> ```
>
> On a host without Docker, ensure nothing else sets the FORWARD policy to DROP.

Then set `uplink` to the physical NIC guests should NAT out through — the
default-route interface is a reasonable choice on a single-uplink host:

```sh
ip route show default | awk '{print $5; exit}'
```

```toml
[network]
# **required**. The physical uplink interface guests NAT egress through.
uplink = "eth0"

# optional, defaults shown
clone_pool = "172.31.0.0/16"
resolver = "1.1.1.1"
```

### Cgroups

Hyper uses cgroups to impose limits on each VM. Each VM has its own cgroup,
which is spawned ephemerally, for the lifetime of the VM. These cgroups are all
managed by a parent cgroup which you must create. You can name this cgroup
whatever you like, as long as it matches the `jails.cgroup` value in the
`/etc/hyper/config.toml`:

```sh
sudo mkdir -p /sys/fs/cgroup/hyper
```

You must allow permissions on `cpu` and `memory` control on the subtree:

```sh
echo '+cpu +memory' | sudo tee /sys/fs/cgroup/hyper/cgroup.subtree_control
```

> #### Security {: .error}
>
> Note that Hyper does not manage the `cgroup` with its user -- it rather
> delegates to `hyper-suidhelper`, which is why `/sys/fs/cgroup/hyper` should
> be `root:root` owned.

> #### Persistence {: .warning}
>
> The configuration, as given, will not survive reboots. To persist it, you can
> use `systemd-tmpfiles`:
>
> ```sh
> echo 'd /sys/fs/cgroup/hyper 0755 root root -' \
>   | sudo tee /etc/tmpfiles.d/hyper-cgroup.conf
> ```

### User Configuration

Hyper must **not** run as `root`, and you should not run it as your login user
either. Instead, give it a dedicated, unprivileged system user. The BEAM runs
as this user; every operation that genuinely needs root is routed through the
setuid helper (see [SUID Helper](#suid-helper)), so the node itself never holds
privilege.

Create the user — system account, no login shell:

```sh
sudo useradd --system --shell /usr/sbin/nologin --home-dir /srv/hyper hyper
```

Start Hyper as this user (for example `sudo -u hyper ...`, or `User=hyper` in a
systemd unit). The rest of this section covers the few permissions it needs —
and the ones it deliberately does **not**.

#### Working directory

The node builds its entire on-disk tree (`jails`, `socks`, `scratch`, `layers`,
`redist`) under `work_dir` (from `/etc/hyper/config.toml`, default `/srv/hyper`)
**as this user**. It must therefore own that directory. Boot validation
(`Hyper.Node.Layer.Repo.test_system/0`) refuses to start unless the `layers`
subdirectory already exists — the node only creates it lazily on first image
load, so pre-create it now:

```sh
sudo mkdir -p /srv/hyper/layers
sudo chown -R hyper:hyper /srv/hyper
```

## Installation

### Hyper Itself

Hyper is a library-first orchestrator: add it to your own Mix project and its
supervision tree boots with your application, turning the node into a VM
runner.

```elixir
def deps do
  [
    {:hypervm, "~> 0.1"}
  ]
end
```

Then `mix deps.get && mix compile`. Alternatively, work from a source
checkout of the [repository](https://github.com/harmont-dev/hyper) — every
step below is identical.

### Firecracker

Hyper drives [Firecracker](https://firecracker-microvm.github.io/) and its
jailer, pinned to a known-good version. Download, verify, and install both
with:

```sh
mix firecracker.install            # installs to /opt/firecracker
```

The task installs the binaries under their bare basenames (`firecracker`,
`jailer` — the setuid helper rejects version-stamped names), marks them
executable, and prints the `[tools]` snippet for `/etc/hyper/config.toml`.
After installing, make both binaries root-owned and not group- or
world-writable (the task prints the exact `chown` command); the helper refuses
them otherwise.

### SUID Helper

Hyper does not run as `root`. Running Hyper as root is considered unsafe and an
anti-pattern. Unfortunately, Hyper needs root for certain classes of system
operations. This is achieved through a side-car binary called
`hyper-suidhelper`, which you must install setuid-root.

> #### Build identity {: .warning}
>
> At boot, Hyper checks that the installed helper is **the exact binary your
> build produced**: `mix compile` stamps the helper with a BLAKE3 checksum and
> bakes that identity into the release, and a deployed helper whose version or
> checksum differs is refused. A binary from another machine or build will not
> pass — always install the helper from the same tree you compiled.

Build and install it with:

```sh
mix suidhelper.install
```

If `sudo` needs a password, the task builds and stamps the binary, then prints
the exact privileged copy for you to run yourself:

```sh
sudo install -o root -g root -m 4755 \
  path/to/built/hyper-suidhelper \
  /usr/local/bin/hyper-suidhelper
```

### Database Migrations

With PostgreSQL reachable (see above) and your database credentials configured
(see the [configuration guide](config.md)), create and migrate the image
database — once per cluster, from any node:

```sh
mix ecto.create -r Hyper.Img.Db.Repo
mix ecto.migrate -r Hyper.Img.Db.Repo
```

## Booting

Start your application as the `hyper` user — Hyper's supervision tree boots
with it and the node becomes a VM runner. From a source checkout, an
interactive session is the quickest smoke test:

```sh
sudo -u hyper iex -S mix
```

At boot Hyper validates the node: config file ownership, the setuid helper's
build identity, and the device-mapper targets. A misconfigured node refuses to
start with a specific error rather than limping along. Once up, load an image
and boot a VM — see the [intro](intro.md#usage) for the walkthrough.

For production, run it under a supervisor of your choice (e.g. a systemd unit
with `User=hyper`). Nodes that join the BEAM cluster become additional VM
runners automatically.

