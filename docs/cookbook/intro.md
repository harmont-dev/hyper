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

#### Auto-redistributed

`umoci` and the guest `vmlinux` kernels are downloaded, checksum-verified, and
managed by Hyper itself; you do not install them.

`firecracker` and `jailer` are not auto-downloaded. Install them with
`mix firecracker.install [--prefix <dir>]` (default prefix `/opt/firecracker`),
which downloads the pinned v1.16.0 release, places the binaries at
`<prefix>/firecracker` and `<prefix>/jailer`, and prints the `/etc/hyper/config.toml`
snippet to paste in.

### Installation

<!-- TODO(markovejnovic): Write this out. -->

### Configuration

Almost all host configuration — `work_dir`, the `[tools]` binary paths
(`firecracker`, `jailer`, `dmsetup`, ...), and the `[jails]` table (`cgroup`,
`uid_gid_range`) — lives in `/etc/hyper/config.toml` (the single source of
truth shared with the setuid helper, shown above), and every node-local path
(`jails`, `socks`, `scratch`, `layers`) is derived from `work_dir`. None of it is
repeated in `config :hyper`.

The node's own tool paths (`skopeo`, `mke2fs`, `umoci`, `suidhelper`) now live in
the `[tools]` table of `/etc/hyper/config.toml` alongside the privileged binaries,
so `config :hyper` holds only the per-architecture guest kernels (each with a
default, so the block may be omitted):

```elixir
config :hyper,
  # Per-architecture guest kernel images placed on the host.
  vmlinux: %{x86_64: "/srv/hyper/redist/vmlinux/vmlinux-x86_64"}
```

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
