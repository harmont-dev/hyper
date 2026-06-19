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
