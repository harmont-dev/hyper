# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Spans from calls that cross nodes join the caller's trace. `Hyper.Rpc.call/5`
  carries the caller's OpenTelemetry context over `:erpc`, and every one of
  Hyper's own `:erpc` hops goes through it; callers outside Hyper do the same
  by calling `Hyper.Rpc.run/4` with `:otel_propagator_text_map.inject([])`.
  `exec` gains spans too: `Hyper.exec` and `Hyper.Node.FireVMM.Agent.exec`,
  which records the call's `outcome` (`ok`, `agent_unavailable`, `timeout`,
  ...) but never its output.
- `Hyper.Img.delete/1` removes an image no VM leases, along with the layer
  files and blob rows no other image shares. Recording an image now checks,
  under a lock, that its blob's file is still in the media store, so a
  concurrent delete of the same bytes can never leave an image without its
  file.

### Changed
- **Breaking:** the gRPC package was promoted `hyper.grpc.v0` -> `hyper.grpc.v1`.
  `google.protobuf.Empty` is replaced by dedicated `StopVmResponse` and
  `ListVmsRequest` messages; the `InstanceType` and `Architecture` enums gained
  `*_UNSPECIFIED = 0` sentinels (existing values renumbered), and an unset
  value is now rejected with `INVALID_ARGUMENT`; `ListVms` is now paginated
  (`page_size` / `page_token` / `next_page_token`).

### Fixed
- A new VM's first inbound connection no longer waits a second. The host answers
  for VM addresses by proxy NDP, which Linux delays by a random time up to 0.8 s;
  the router dropped the SYN it held meanwhile, and TCP resent it after its 1 s
  timeout. `host_init` now sets the uplink's `proxy_delay` to 0.

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
