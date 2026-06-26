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

**The config file must exist** to set `firecracker` and `jailer` (no built-in
defaults for those). The device-tool paths (`dmsetup`, `losetup`, `blockdev`)
and `work_dir` do have built-in defaults, so if you only need those defaults
and are not running VMs you may omit the file entirely. When the file is
present it must be root-owned and not group/other-writable, or the helper
refuses to start (a present-but-untrusted file is treated as an attack signal,
unlike a missing one):

```toml
# /etc/hyper/config.toml (root-owned, mode 0644)
work_dir = "/srv/hyper"

# REQUIRED - no default. Each must be an absolute path to a root-owned,
# non-group/world-writable binary named exactly "firecracker" or "jailer"
# (the helper validates the basename). Run `mix firecracker.install` to
# download the pinned release and print these values.
firecracker = "/opt/firecracker/firecracker"
jailer      = "/opt/firecracker/jailer"

# Optional device-tool overrides; default to /usr/sbin/{dmsetup,losetup,blockdev}.
# Each must be root-owned and not group/world-writable.
dmsetup  = "/usr/sbin/dmsetup"
losetup  = "/usr/sbin/losetup"
blockdev = "/usr/sbin/blockdev"

# Optional. Governs which uid/gid values the helper accepts when launching the
# jailer. Must satisfy min > 0 and min <= max. Defaults to {900000, 999999}.
# If you narrow this range, set the same bounds in `config :hyper, uid_gid_range:`
# so the node hands out only uids the helper will accept.
[uid_gid_range]
min = 900000
max = 999999
```

`dmsetup` (lvm2) is frequently *not* installed by default - check that one
first.

#### Kernel features

The host kernel must provide:

  - **KVM** - `/dev/kvm` must exist and be accessible to the per-VM users (see
    the `uid_gid_range` configuration).
  - **cgroup v2** - the unified hierarchy mounted at `/sys/fs/cgroup`. v1-only
    hosts are not supported.
  - **device-mapper targets** `snapshot`, `thin`, and `thin-pool` - from the
    `dm_snapshot` (provides `snapshot`) and `dm_thin_pool` (provides `thin` and
    `thin-pool`) modules. Hyper refuses to start without all three; on boot it
    fails with `{:missing_dm_targets, [...]}` listing whichever are absent.
  - **loop devices** - the `loop` module, used to attach layer images as block
    devices.

Load the modules and confirm the targets are present:

```sh
sudo modprobe dm_snapshot dm_thin_pool loop
sudo dmsetup targets        # must list snapshot, thin, and thin-pool
```

If `modprobe` reports the module is missing, the running kernel lacks it -
minimal cloud images often strip device-mapper. On Debian/Ubuntu, install the
extra modules for the running kernel, then load them:

```sh
sudo apt-get install -y linux-modules-extra-$(uname -r)
sudo modprobe dm_snapshot dm_thin_pool loop
```

Make the modules load on every boot:

```sh
printf 'dm_snapshot\ndm_thin_pool\nloop\n' | sudo tee /etc/modules-load.d/hyper.conf
```

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
    under the cgroup-v2 hierarchy; Hyper creates each VM's cgroup beneath it and
    fails to boot with `:missing_parent_cgroup` if it is absent. Create it and
    delegate the `cpu` and `memory` controllers so the per-VM cgroups can set
    `cpu.max` / `memory.max`:

    ```sh
    sudo mkdir -p /sys/fs/cgroup/hyper
    echo '+cpu +memory' | sudo tee /sys/fs/cgroup/hyper/cgroup.subtree_control
    ```

    If that last write errors, the root hierarchy is not delegating those
    controllers down yet - enable them there first, then retry the line above:

    ```sh
    echo '+cpu +memory' | sudo tee /sys/fs/cgroup/cgroup.subtree_control
    ```

    The cgroup hierarchy is memory-backed, so `/sys/fs/cgroup/hyper` does **not**
    survive a reboot. Re-create it each boot, or persist it with
    `systemd-tmpfiles`:

    ```sh
    echo 'd /sys/fs/cgroup/hyper 0755 root root -' \
      | sudo tee /etc/tmpfiles.d/hyper-cgroup.conf
    ```
  - The host UID/GID range must be free for Hyper to allocate per-VM users
    from. The node's range is set by `uid_gid_range` in `config :hyper`; the
    helper independently reads `[uid_gid_range]` from `/etc/hyper/config.toml`
    (see below) and only accepts jailer `--uid`/`--gid` within that range.
    Keep the two in sync.

#### Auto-redistributed

`umoci` and the guest `vmlinux` kernels are downloaded, checksum-verified, and
managed by Hyper itself; you do not install them.

`firecracker` and `jailer` are not auto-downloaded. Install them with
`mix firecracker.install [--prefix <dir>]` (default prefix `/opt/firecracker`),
which downloads the pinned v1.16.0 release, places the binaries at
`<prefix>/firecracker` and `<prefix>/jailer`, and prints the config snippets to
paste into `/etc/hyper/config.toml` and `config.exs`.

### Installation

<!-- TODO(markovejnovic): Write this out. -->

### Configuration

Running `Hyper` is involved and requires a large number of pre-requisites. The
configuration of `:hyper` can be done by creating a `config :hyper` entry in
your `config.exs`. Refer to the given snippet for details on each
configuration.

```elixir
config :hyper,
  # REQUIRED. Must point at the bare-basename binaries installed by
  # `mix firecracker.install`. The setuid helper validates these paths
  # (root-owned, non-group/world-writable, basename exactly "firecracker"/"jailer").
  firecracker_bin: "/opt/firecracker/firecracker",
  jailer_bin: "/opt/firecracker/jailer",
  # You must create a parent cgroup on your system. Continue reading for
  # further details.
  cgroup_parent: "hyper",
  jailer_chroot_base: "/srv/hyper/jails",
  socket_dir: "/srv/hyper/socks",
  scratch_dir: "/srv/hyper/scratch",
  # Must match the [uid_gid_range] table in /etc/hyper/config.toml so the node
  # hands out only uids the helper will accept.
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
