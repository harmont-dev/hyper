# Intro

`Hyper` is a distributed VM orchestrator, similar to
[Daytona](https://www.daytona.io/), [Runloop](https://runloop.ai/), etc.
Although, at this stage, `Hyper` is a smaller project than any of these
existing products, it aims to achieve similar, if not better, performance
characteristics at scale, while ensuring extremely high availability and fault
tolerance.

`Hyper` has been developed completely greenfield, with no reference to any of
the aforementioned systems.

The absolute best way to understand `Hyper` and how it works is to play around
with it.

## Getting Started

Running `Hyper` requires a Linux host with KVM, a handful of OS packages, a
PostgreSQL database, and two privileged artifacts (the Firecracker binaries and
the setuid helper). The [installation guide](install.md) walks through every
step; the [configuration guide](config.md) documents every knob. This page
gives you the shape of things.

### Installation

Follow the [installation guide](install.md). In short:

1. Prepare the host: KVM, cgroups v2, device-mapper modules, OS packages,
   PostgreSQL, a dedicated unprivileged `hyper` user.
2. Add `hypervm` to your Mix project's dependencies (or work from a source
   checkout).
3. Install the Firecracker binaries (`mix firecracker.install`) and the setuid
   helper (`mix suidhelper.install`).
4. Write `/etc/hyper/config.toml` and run the database migrations.

### Configuration

All node configuration lives in two root-owned files: `/etc/hyper/config.toml`
(static settings, shared with the setuid helper) and, optionally,
`/etc/hyper/config.exs` (runtime Elixir config — secrets, cluster topology).
The [configuration guide](config.md) documents the full four-layer precedence
and every table; the [installation guide](install.md#configuration) shows a
minimal working `config.toml`.

### Usage

Hyper is a library-first orchestrator: add it as a dependency and its
supervision tree boots with your application, turning the node into a VM
runner. Nodes that join the BEAM cluster become additional runners
automatically. For non-BEAM consumers there is an optional
[gRPC interface](../grpc.md).

#### Loading Images

Before an image can be booted, it needs to be loaded into Hyper. Currently,
the only way to load images is through an OCI image, either through the native
interface, or through [gRPC](../grpc.md):

```elixir
{:ok, img_id} = Hyper.Img.OciLoader.load("docker.io/library/alpine:3.19")
```

#### Booting a VM

With the image loaded, and an `img_id` in hand, you can boot it:

```elixir
{:ok, vm} = Hyper.create_vm(%Hyper.Vm.Spec{img_id: img_id, type: :micro})
```

The VM is scheduled onto the most available node in the cluster, preferring
nodes that already hold the image's layers.

#### Running Commands

`Hyper.exec/3` runs a command inside the guest and captures its output. Use an
absolute path for the executable — the guest boots with a near-empty
environment, so there is no `PATH` to resolve bare names against:

```elixir
{:ok, %{stdout: out, exit_code: 0}} = Hyper.exec(vm, ["/bin/echo", "hello"])
```
