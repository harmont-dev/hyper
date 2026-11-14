# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Security
- **Breaking:** the setuid helper now runs privileged operations only for root
  and for members of the group it is installed with, and moves to
  `/usr/local/libexec/hyper/hyper-suidhelper` (`root:<node group>`, mode
  `4750`, in a `0750` directory). Previously any local account could drive it
  against every VM: claim a VM's vsock socket (root exec in the guest), tear
  VMs down, or map files under `work_dir`. Upgrade by running
  `mix suidhelper.install` as the node's account, or the commands in
  `docs/cookbook/install.md`; this also removes the old
  `/usr/local/bin/hyper-suidhelper`, which must not be left behind. A helper
  installed with group `root` refuses everyone but root. (#117)

### Changed
- **Breaking:** the gRPC package was promoted `hyper.grpc.v0` -> `hyper.grpc.v1`.
  `google.protobuf.Empty` is replaced by dedicated `StopVmResponse` and
  `ListVmsRequest` messages; the `InstanceType` and `Architecture` enums gained
  `*_UNSPECIFIED = 0` sentinels (existing values renumbered), and an unset
  value is now rejected with `INVALID_ARGUMENT`; `ListVms` is now paginated
  (`page_size` / `page_token` / `next_page_token`).

## [0.1.0]

First public release: a distributed orchestrator for Firecracker microVMs on the
BEAM.

### Added
- Firecracker microVM lifecycle: create, stop, locate, and list VMs across a
  cluster, with automatic layer-affinity placement.
- Content-addressed OCI image loading into a shared media store + image database.
- Copy-on-write disk **forking** (`Hyper.Vm.fork/1` and the `ForkVm` gRPC RPC):
  colocated thin-snapshot forks with a cluster-wide delta-layer fallback.
- Per-VM egress networking: netns + TAP + nftables NAT.
- Granular per-VM compute metering (CPU-time, from the cgroup) for billing.
- Guest exec over vsock (`Hyper.exec/3`).
- gRPC interface (`hyper.grpc.v0`, UNSTABLE) — off by default, unauthenticated.
- Privileged Rust setuid helper for the host operations the BEAM cannot do safely.
- OpenTelemetry tracing across the subsystems.

[Unreleased]: https://github.com/harmont-dev/hyper/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/harmont-dev/hyper/releases/tag/v0.1.0
