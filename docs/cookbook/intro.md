# Intro

`Hyper` is a distributed VM orchestrator, similar to
[Daytona](https://www.daytona.io/), [Runloop](https://runloop.ai/), etc.
Although, at this stage, `Hyper` is a smaller project than any of these
existing products, it aims to achieve similar, if not better, performance
characteristics at scale, while ensuring extremely high availability and fault
tolerance.

`Hyper` has been developed completely greenfield, with no reference to any of
of the aforementioned systems.

The absolute best way to understand `Hyper` and how it works is to play around
with it.

## Getting Started

The absolute best way to get started with `Hyper` is to play with it.

### Requirements

#### External services

Hyper needs a **PostgreSQL** server reachable from every node — it is the image
database and the only stateful external dependency.

#### System binaries

The following must be on each node's `PATH` (the bracketed override is the
`config :hyper` key you can set if the binary lives elsewhere):

  - [`skopeo`](https://github.com/containers/skopeo) — pulls OCI images
    (`skopeo_path`)
  - [`e2fsprogs`](https://github.com/tytso/e2fsprogs) — provides `mke2fs`, which
    builds the ext4 rootfs (`mke2fs_path`)
  - `losetup`, `blockdev` (from **util-linux**) — loop-device setup
    (`losetup_path`, `blockdev_path`)
  - `dmsetup` (from **lvm2** / device-mapper) — dm-snapshot and thin-pool
    layering (`dmsetup_path`). Frequently *not* installed by default — check
    this one first.
  - `du`, `getent` (from **coreutils** and **glibc**) — rootfs sizing and user
    resolution. Present on essentially every distro.

#### Kernel features

The host kernel must provide:

  - **KVM** — `/dev/kvm` must exist and be accessible to the per-VM users (see
    the `uid_gid_range` configuration).
  - **cgroup v2** — the unified hierarchy mounted at `/sys/fs/cgroup`. v1-only
    hosts are not supported.
  - **device-mapper targets** `snapshot`, `thin`, and `thin-pool` — load the
    `dm_snapshot` and `dm_thin_pool` modules (`modprobe dm_snapshot
    dm_thin_pool`). Hyper refuses to start its device helper without them.
  - **loop devices** — the `loop` module, used to attach layer images as block
    devices.

#### Privileged setup

  - The **setuid-root device helper** (`hyper-suidhelper`) must be installed.
    Run `mix suidhelper.install`, which builds, stamps, and places it
    setuid-root on `PATH`. Every privileged operation (losetup, dmsetup, mknod,
    chroot jails) routes through it; the BEAM itself runs unprivileged.
  - A **parent cgroup** named by `cgroup_parent` (default `hyper`) must exist
    under `/sys/fs/cgroup`; Hyper creates each VM's cgroup beneath it.
  - The host UID/GID range given by `uid_gid_range` must be free for Hyper to
    allocate per-VM users from.

#### Auto-redistributed

The remaining runtime dependencies — `firecracker`, `jailer`, `umoci`, and the
guest `vmlinux` kernels — are downloaded, checksum-verified, and managed by
Hyper itself; you do not install them.

### Installation

<!-- TODO(markovejnovic): Write this out. -->

### Configuration

Running `Hyper` is involved and requires a large number of pre-requisites. The
configuration of `:hyper` can be done by creating a `config :hyper` entry in
your `config.exs`. Refer to the given snippet for details on each
configuration.

```elixir
config :hyper,
  # TODO(markovejnovic): Remove this after it gets auto-downloaded.
  jailer_bin: "/opt/firecracker/jailer-v1.16.0-x86_64",
  # TODO(markovejnovic): Remove this after it gets auto-downloaded.
  firecracker_bin: "/opt/firecracker/firecracker-v1.16.0-x86_64",
  # You must create a parent cgroup on your system. Continue reading for
  # further details.
  cgroup_parent: "hyper",
  # TODO(markovejnovic): Merge these directories into one.
  jailer_chroot_base: "/srv/hyper/jails",
  socket_dir: "/srv/hyper/socks",
  scratch_dir: "/srv/hyper/scratch",
  # Hyper requires that each VM you pass 
  uid_gid_range: {900_000, 999_999},
  layer_dir: "/srv/hyper/layers"
```

<!-- TODO(markovejnovic): Update the config section. -->

### Usage

<!-- TODO(markovejnovic): Write out how to boot hyper etc -->

#### Loading Images

Before an image can be booted, it needs to be loaded into Hyper. Currently, the
only way to load images is through an OCI image, either natively or through the
native interface, or through [gRPC](../grpc.md):

```elixir
{:ok, img_id} = Hyper.Img.OciLoader.load("docker.io/library/alpine:3.19")
```

#### Booting a VM

With the image loaded, and an `img_id` in hand, you can boot it:

```elixir
{:ok, vm} = Hyper.create_vm(%Hyper.Vm.Spec{ img_id: img_id })
```
