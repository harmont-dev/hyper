# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Breaking:** VM networking, rebuilt. Each VM runs in its own network
  namespace: outbound IPv4 through a per-VM and a host-wide NAT (nftables),
  and a globally routable IPv6 address from `<prefix>:1::/80`, announced to
  the upstream network by proxy NDP. A node now requires a `[net]` table
  (`uplink`, `ipv6_prefix`) and the `nft` binary; `host_init` turns on
  forwarding and proxy NDP itself. The setuid helper's `vm_launch` request
  takes a `net_id` and a `firewall`, and its `net_*` requests are gone. See
  `docs/cookbook/networking.md`.
- VM firewalls. VMs cannot reach the host, private or link-local ranges, or
  send from addresses that are not theirs. Each VM has a port policy:
  inbound ports open to it and outbound ports it may not use, set at
  `CreateVm` (`firewall`, defaulting to nothing open and outbound TCP 25
  blocked) and replaced at runtime with the new `SetVmFirewall` RPC. Forks
  inherit the parent's current policy. The setuid helper gains `vm_firewall`.

### Changed
- **Breaking:** the gRPC package was promoted `hyper.grpc.v0` -> `hyper.grpc.v1`.
  `google.protobuf.Empty` is replaced by dedicated `StopVmResponse` and
  `ListVmsRequest` messages; the `InstanceType` and `Architecture` enums gained
  `*_UNSPECIFIED = 0` sentinels (existing values renumbered), and an unset
  value is now rejected with `INVALID_ARGUMENT`; `ListVms` is now paginated
  (`page_size` / `page_token` / `next_page_token`).

### Removed
- **Breaking:** the previous VM networking is gone, replaced by the design
  above: the `[network]` config table, the `172.30.0.0/30` guest addressing,
  the `Hyper.SuidHelper.Network` module and the setuid helper's `network`
  subcommands. Guests no longer get an `/etc/resolv.conf` from
  `hyper.resolver=`; DNS configuration is not yet part of the new design.

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
