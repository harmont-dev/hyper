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

Hyper requires the following software be installed on each node running it:

  - [`skopeo`](https://github.com/containers/skopeo)
  - [`e2fsprogs`](https://github.com/tytso/e2fsprogs)

Hyper has more runtime dependencies, but they are automatically redistributed
by Hyper.

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
