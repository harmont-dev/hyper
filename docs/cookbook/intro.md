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

Once it is up, create and migrate the schema (the repo is not in `ecto_repos`,
so pass it with `-r`):

```sh
mix ecto.create -r Hyper.Img.Db.Repo
mix ecto.migrate -r Hyper.Img.Db.Repo
```

The container is ephemeral; `docker start hyper-pg` brings it back after a
reboot. To point Hyper at an existing server instead, override the
`Hyper.Img.Db.Repo` block in your `config.exs`.

#### System binaries

These are used by the unprivileged node directly; each must be on the node's
`PATH` (the bracketed override is the `config :hyper` key you can set if the
binary lives elsewhere):

  - [`skopeo`](https://github.com/containers/skopeo) - pulls OCI images
    (`skopeo_path`)
  - [`e2fsprogs`](https://github.com/tytso/e2fsprogs) - provides `mke2fs`, which
    builds the ext4 rootfs (`mke2fs_path`)
  - `du`, `getent` (from **coreutils** and **glibc**) - rootfs sizing and user
    resolution. Present on essentially every distro.

The privileged device binaries - `losetup`, `blockdev` (from **util-linux**)
and `dmsetup` (from **lvm2** / device-mapper) - are run only by the setuid
helper, never named by the unprivileged caller. Their paths therefore live in
the helper's own config, `/etc/hyper/config.toml`, and default to
`/usr/sbin/{losetup,blockdev,dmsetup}`.

**The config file is optional.** If it is absent the helper uses the built-in
defaults below (and `work_dir = "/srv/hyper"`, matching the node's own
fallback). Create one only to override a default - and if you do, it must be
root-owned and not group/other-writable, or the helper refuses to start (a
present-but-untrusted file is treated as an attack signal, unlike a missing
one):

```toml
# /etc/hyper/config.toml (root-owned, mode 0644) - every line optional
work_dir = "/srv/hyper"

# Each must be an absolute path to a root-owned, non-world-writable binary;
# the helper validates this before it will exec the tool.
dmsetup  = "/usr/sbin/dmsetup"
losetup  = "/usr/sbin/losetup"
blockdev = "/usr/sbin/blockdev"
```

`dmsetup` (lvm2) is frequently *not* installed by default - check that one
first.

#### Kernel features

The host kernel must provide:

  - **KVM** - `/dev/kvm` must exist and be accessible to the per-VM users (see
    the `uid_gid_range` configuration).
  - **cgroup v2** - the unified hierarchy mounted at `/sys/fs/cgroup`. v1-only
    hosts are not supported.
  - **device-mapper targets** `snapshot`, `thin`, and `thin-pool` - load the
    `dm_snapshot` and `dm_thin_pool` modules (`modprobe dm_snapshot
    dm_thin_pool`). Hyper refuses to start its device helper without them.
  - **loop devices** - the `loop` module, used to attach layer images as block
    devices.

#### Privileged setup

  - The **setuid-root device helper** (`hyper-suidhelper`) must be installed.
    Run `mix suidhelper.install`, which builds, stamps, and places it
    setuid-root on `PATH`. Every privileged operation (losetup, dmsetup, mknod,
    chroot jails) routes through it; the BEAM itself runs unprivileged.

    The final `sudo install` step runs without a controlling terminal (Mix
    captures the nested `cargo` output), so on a typical `tty_tickets` sudo
    setup it cannot prompt for a password. If it fails, the build has already
    stamped the binary -- just run the copy yourself:

    ```sh
    sudo install -o root -g root -m 4755 \
      native/suidhelper/target/release/hyper-suidhelper \
      /usr/local/bin/hyper-suidhelper
    ```
  - A **parent cgroup** named by `cgroup_parent` (default `hyper`) must exist
    under `/sys/fs/cgroup`; Hyper creates each VM's cgroup beneath it.
  - The host UID/GID range given by `uid_gid_range` must be free for Hyper to
    allocate per-VM users from.

#### Auto-redistributed

The remaining runtime dependencies - `firecracker`, `jailer`, `umoci`, and the
guest `vmlinux` kernels - are downloaded, checksum-verified, and managed by
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
