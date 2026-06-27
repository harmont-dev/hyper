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
  util-linux
```

### Rocky

You can install the required packages by running:

```sh
sudo dnf install -y \
  coreutils \
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

<!-- tabs-close -->

### Device Mapper Config

Hyper relies on `dm-snapshot` and `dm-thin` to build COW filesystems. Load the
modules and confirm the targets are present:

```sh
sudo modprobe dm_snapshot dm_thin_pool loop
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
> use `systemd-tempfiles`:
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
**as this user**. It must therefore own that directory:

```sh
sudo mkdir -p /srv/hyper
sudo chown hyper:hyper /srv/hyper
```

## Installation

### SUID Helper

Hyper does not run as `root`. Running Hyper as root is considered unsafe and an
anti-pattern. Unfortunately, Hyper needs root for certain classes of system
operations. This is achieved through a side-car binary called
`hyper-setuidhelper`, which you must install manually.

> #### Versioning {: .warning}
>
> The `hyper-setuidhelper` binary is versioned together with the version of
> `Hyper`, meaning that mismatched versions between the `hyper-setuidhelper`
> and `Hyper` itself will not work and Hyper will fail to boot.

Installing this binary can be done by downloading it from the [Github Releases
page](https://github.com/harmont-dev/hyper/releases) and executing:

```sh
sudo install -o root -g root -m 4755 \
  path/to/downloaded/hyper-suidehelper \
  /usr/local/bin/hyper-suidhelper
```

