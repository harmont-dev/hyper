# Hyper

Hyper is a distributed orchestrator for [Firecracker](https://firecracker-microvm.github.io/)
microVMs. It schedules virtual machines across a cluster of nodes and boots
them from a shared, copy-on-write image store, so that VMs start fast and reuse
disk that is already resident on a node.

> **Status:** early and under active development. Interfaces and behavior are
> expected to change.

## What it does

- **Distributed scheduling.** Add nodes to grow the cluster; Hyper places
  incoming VMs onto nodes that can satisfy their resource requirements. Placement
  is driven by per-node **hard budgets** (memory, disk — exceeding them crashes
  VMs) and **soft budgets** (vCPU, disk/network bandwidth — exceeding them only
  degrades performance).

- **Copy-on-write images and layers.** An image is a chain of layers that
  compose as COW block devices — a base layer, any number of immutable
  intermediate layers, and an optional mutable top layer. Layers are stacked at
  runtime with `losetup`, `dm-snapshot`, and `dm-thin`. This keeps stored bytes
  small (only diffs are kept) and makes forking a VM cheap.

- **Colocation-aware placement.** Because the shared layer store is far larger
  and slower than a node's local NVMe, Hyper prefers nodes that already have a
  VM's required layers mounted, avoiding a slow layer download on boot.

- **Shared storage + metadata.** Layer and image blobs live on a shared pool
  filesystem (local, NFS, S3, or similar). A side-car PostgreSQL database tracks
  layer/image dependencies and the leases that mark which layers are currently
  in use.

For the full design — layer algebra, budgets, and the scheduling strategy — see
the [architecture guide](docs/cookbook/architecture.md).

## How it works

Hyper is built in Elixir/OTP. It uses [libcluster](https://github.com/bitwalker/libcluster)
for node discovery and [Horde](https://github.com/derekkraan/horde) for
distributed process supervision, runs each VM under the Firecracker
[jailer](https://github.com/firecracker-microvm/firecracker/blob/main/docs/jailer.md)
(cgroups v2 + chroot isolation), and emits [OpenTelemetry](https://opentelemetry.io/)
traces.

## Requirements

- Linux with KVM, cgroups v2, and `dmsetup` / `losetup` available
- Firecracker and its jailer binary
- PostgreSQL (metadata database)
- A shared layer storage medium reachable by every node

## Installation

The package can be added to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:hyper, "~> 0.1.0"}
  ]
end
```

## License

Hyper is licensed under the GNU Affero General Public License v3.0 or later
(AGPL-3.0-or-later). See [LICENSE](LICENSE) and [NOTICE](NOTICE). Contributions
are governed by the [Contributor License Agreement](CLA.md).
