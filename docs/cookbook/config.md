# Configuration

Configuring `Hyper` is done through four layers, in priority:

  1. Runtime `/etc/hyper/config.exs` is the canonical Elixir way to configure
     the system. This allows you to inject arbitrary code to configure `Hyper`.
  2. `Hyper` will fall back to reading `/etc/hyper/config.toml` at runtime, on
     bootup, on each node.
  3. `Hyper` will use its compile-time configuration through `config.ex`.
  4. `Hyper` will use defaults.

**Note that not all layers allow all configuration fields to be tweaked.** This
is usually done for security.

## Configuration Files

### `/etc/hyper/config.exs`

The `config.exs` file is exlusively used by the unprivileged `hyper`
application. The purpose of this file is to allow you to load configuration
values at runtime. If you are using a secrets manager, this is the right place
to load the secrets.

### `/etc/hyper/config.toml`

The `/etc/hyper/config.toml` file is used for static configuration. Unlike
`config.exs`, it is used by both `Hyper` and `hyper-suidhelper` which means
that it can impact the behavior of a process running under `root`.

### Compile-Time Config

The compile-time configuration is generally used to fine-tune the performance
of Hyper. You likely do not need to edit most of the configuration fields
exposed by this file for day-to-day usage, but they are available for you to
tweak.

## Configuration Fields

### Tool Configuration

Hyper relies on a large number of external tools, all configured under the
`[tools]` table in `/etc/hyper/config.toml`.

#### Privileged tools (run by the setuid helper)

| Tool | Required | Default | `/etc/hyper/config.toml` |
|------|----------|---------|--------------------------|
| `firecracker` | Yes | - | `tools.firecracker` |
| `jailer` | Yes | - | `tools.jailer` |
| `dmsetup` | No | `/usr/sbin/dmsetup` | `tools.dmsetup` |
| `losetup` | No | `/usr/sbin/losetup` | `tools.losetup` |
| `blockdev` | No | `/usr/sbin/blockdev` | `tools.blockdev` |

> #### Requirements {: .info}
>
> - These paths **can only** be configured through `/etc/hyper/config.toml`.
>   Both `Hyper` and `hyper-setuidhelper` rely on these paths being identical.
>
> - The paths **must** be given as absolute paths.
> - The basename **must** match the configuration, eg. `firecracker` must have
>   a path `/foo/bar/firecracker`.
> - The tools must be owned by the `root` user.
> - The tools must be exlusively writable by `root`.

#### Node tools (run by the unprivileged node)

| Tool | Required | Default | `/etc/hyper/config.toml` |
|------|----------|---------|--------------------------|
| `skopeo` | No | `skopeo` (on `PATH`) | `tools.skopeo` |
| `mke2fs` | No | `mke2fs` (on `PATH`) | `tools.mke2fs` |
| `umoci` | No | downloaded + cached under `<work_dir>/redist/umoci` | `tools.umoci` |
| `suidhelper` | No | `/usr/local/bin/hyper-suidhelper` | `tools.suidhelper` |

> #### These are not privileged {: .info}
>
> The node runs these directly as the unprivileged hyper user, so — unlike the
> privileged tools above — they carry **no** root-ownership or basename
> requirement. `skopeo`/`mke2fs` default to the bare name resolved on `PATH`;
> leave `umoci` unset to let Hyper download and cache a pinned release. They
> share the one `[tools]` table with the privileged binaries — the helper simply
> ignores the keys it does not own.

## The shared file: `/etc/hyper/config.toml`

> #### Security {: .error}
>
> This file **must** be owned by `root` and be neither group- nor
> world-writable (e.g. mode `0644`). The setuid helper refuses to start
> otherwise — a present-but-untrusted file is treated as operator
> misconfiguration and is fatal (exit `2`), never silently ignored.

### Root keys

| Key | Type | Default | Meaning |
|-----|------|---------|---------|
| `work_dir` | string (absolute path) | `/srv/hyper` | Root of all node-local runtime state. Every other directory is derived from it. Must be an absolute path. Strongly recommended to sit on an NVMe drive. |

The following directories are derived from `work_dir` and are **not**
independently configurable:

| Path | Purpose |
|------|---------|
| `<work_dir>/jails` | Per-VM chroot directories |
| `<work_dir>/socks` | Per-VM control/gRPC sockets |
| `<work_dir>/scratch` | Per-VM copy-on-write writable layers |
| `<work_dir>/layers` | Read-only image layer store |
| `<work_dir>/redist` | Node-downloaded binaries (`vmlinux`, `umoci`) |

### `[jails]` — confinement

| Key | Type | Default | Meaning |
|-----|------|---------|---------|
| `cgroup` | string | `"hyper"` | Parent cgroup under which every VM cgroup is nested (passed to the jailer as `--parent-cgroup`). The operator must create `/sys/fs/cgroup/<name>` and enable subtree control. |
| `uid_gid_range` | `[min, max]` | `[900000, 999999]` | UID/GID band each VM jail is allocated from. `min` must be `>= 1` and `<= max`; `min = 0` is rejected (uid 0 is root, and the jailer skips its privilege drop for uid 0). |

> #### `uid_gid_range` is enforced on both sides {: .warning}
>
> The node only hands out UIDs in this range, and the helper only *accepts*
> UIDs in this range. Because both read the same file, narrowing the band is a
> single edit here — no second place to keep in sync. Nothing else on the host
> may use UIDs/GIDs in this range.

### Complete example

```toml
# Root of all node-local state. Strongly prefer an NVMe-backed mount.
work_dir = "/srv/hyper"

# External binaries. The privileged ones (firecracker..blockdev) must be
# root-owned, not group/world-writable, absolute, and named exactly as their
# key; the node tools (skopeo/mke2fs/umoci/suidhelper) have no such requirement.
[tools]
firecracker = "/opt/firecracker/firecracker"   # required; basename must be 'firecracker'
jailer      = "/opt/firecracker/jailer"         # required; basename must be 'jailer'
# dmsetup    = "/usr/sbin/dmsetup"              # optional (default shown)
# losetup    = "/usr/sbin/losetup"              # optional (default shown)
# blockdev   = "/usr/sbin/blockdev"             # optional (default shown)
# skopeo     = "skopeo"                          # optional node tool (default shown)
# mke2fs     = "mke2fs"                          # optional node tool (default shown)
# umoci      = "/usr/bin/umoci"                  # optional; omit to auto-download
# suidhelper = "/usr/local/bin/hyper-suidhelper" # optional (default shown)

[jails]
cgroup        = "hyper"               # default
uid_gid_range = [900000, 999999]      # default
```

The minimal file is just `work_dir` plus the two required tools — everything
else defaults.

## Node-only configuration (`config :hyper`)

These have no helper counterpart and stay in `config :hyper`. The node's tool
paths (`skopeo`, `mke2fs`, `umoci`, `suidhelper`) used to live here but now read
from the `[tools]` table above — see [Tool Configuration](#tool-configuration).

### Guest kernels

| Key | Where read | Type | Default | Meaning |
|-----|-----------|------|---------|---------|
| `vmlinux` | runtime | `%{arch => path}` | `%{}` | Per-architecture guest kernel images, keyed by `Sys.Arch.t()`. The operator places kernels on the host and points these at them. |

```elixir
config :hyper,
  vmlinux: %{x86_64: "/srv/hyper/redist/vmlinux/vmlinux-x86_64"}
```

### Resource budget — `Hyper.Node.Config.Budget`

The per-node resource budget. **Required**: the node refuses to boot if it is
absent. Set it in `config/runtime.exs`. Use the `Unit.*` quantities, never bare
numbers.

| Key | Type | Meaning |
|-----|------|---------|
| `mem_max` | `Unit.Information.t()` | Hard memory cap for this node. |
| `disk_max` | `Unit.Information.t()` | Hard disk cap for this node. |
| `cpu_max_load` | float `0.0..1.0` | CPU-utilization fraction above which the node is considered full. |
| `disk_bw_cap` | `Unit.Bandwidth.t()` | Absolute disk throughput capacity. |
| `disk_bw_max_load` | float `0.0..1.0` | Fraction of `disk_bw_cap` past which disk is saturated. |
| `net_bw_cap` | `Unit.Bandwidth.t()` | Absolute network throughput capacity. |
| `net_bw_max_load` | float `0.0..1.0` | Fraction of `net_bw_cap` past which network is saturated. |

```elixir
config :hyper, Hyper.Node.Config.Budget,
  mem_max: Unit.Information.gib(4),
  disk_max: Unit.Information.gib(4),
  cpu_max_load: 0.8,
  disk_bw_cap: Unit.Bandwidth.gibps(1),
  disk_bw_max_load: 0.8,
  net_bw_cap: Unit.Bandwidth.gibps(1),
  net_bw_max_load: 0.8
```

### gRPC server — `Hyper.Grpc.Config`

The public gRPC interface. **Disabled by default.**

| Key | Type | Default | Meaning |
|-----|------|---------|---------|
| `enabled` | boolean | `false` | Whether the server starts. |
| `port` | port number | `50051` | Listen port. |
| `cred` | `GRPC.Credential.t()` \| `nil` | `nil` | TLS credential, or `nil` for plaintext. |
| `adapter_opts` | keyword | `[]` | Forwarded to the server adapter, e.g. `[ip: {0, 0, 0, 0}]`. |

```elixir
config :hyper, Hyper.Grpc.Config,
  enabled: true,
  port: 50_051,
  cred: GRPC.Credential.new(ssl: [certfile: "/path/cert.pem", keyfile: "/path/key.pem"])
```

> #### Co-located nodes {: .info}
>
> Every node binds `:port`. Running multiple nodes on one host requires giving
> each a distinct port. Build the TLS credential where you load your keys
> (e.g. `config/runtime.exs`); Hyper never reads the filesystem on your behalf.

### Layer garbage collector — `Hyper.Img.Db.Gc.Config`

A cluster-wide singleton that prunes unreferenced image layers. Every field has
a default; set only what you change. Durations are `Unit.Time` values, so
overrides belong in `config/runtime.exs`. Set `enabled: false` to never start it.

| Key | Type | Default | Meaning |
|-----|------|---------|---------|
| `enabled` | boolean | `true` | Run the collector at all. |
| `batch_size` | `pos_integer` | `200` | Rows per keyset page (smaller = finer pause granularity). |
| `batch_pause` | `Unit.Time.t()` | `100ms` | Pause between pages within a sweep. |
| `sweep_interval` | `Unit.Time.t()` | `60s` | Rest between completed sweeps. |
| `acquire_interval` | `Unit.Time.t()` | `5s` | How often a standby retries to become the active singleton. |
| `retry` | `Unit.Time.t()` | `60s` | Backoff when the medium or DB is unavailable. |
| `statement_timeout` | `Unit.Time.t()` | `5s` | Cap on each GC DB statement so it can't pin a backend. |
| `grace_period` | `Unit.Time.t()` | `1h` | Never prune a blob younger than this (protects a row whose file is still being published). |

```elixir
config :hyper, Hyper.Img.Db.Gc.Config,
  enabled: true,
  sweep_interval: Unit.Time.s(30),
  grace_period: Unit.Time.s(60 * 60)
```

### Orphaned-resource reaper — `Hyper.Node.Reaper.Config`

A per-node sweeper that reclaims orphaned firecracker cgroups and `hyper-rw-*`
device-mapper volumes left behind by unclean BEAM deaths. Uses a two-strike
grace period (an orphan must be seen on two consecutive ticks before it is
reaped). Set `enabled: false` to never start it.

| Key | Type | Default | Meaning |
|-----|------|---------|---------|
| `enabled` | boolean | `true` | Run the reaper at all. |
| `interval` | `Unit.Time.t()` | `60s` | Rest between reap ticks. |

```elixir
config :hyper, Hyper.Node.Reaper.Config,
  enabled: true,
  interval: Unit.Time.s(30)
```

### Telemetry (OpenTelemetry)

Tracing is configured in `config/runtime.exs` from environment variables:

| Variable | Effect |
|----------|--------|
| `HONEYCOMB_API_KEY` | Export to `https://api.honeycomb.io` with this key. |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | If `HONEYCOMB_API_KEY` is unset, export to this OTLP/HTTP endpoint (e.g. a local Collector), no auth header. |

If neither is set, tracing is disabled.

### Database and cluster topology

The image-metadata database (`Hyper.Img.Db.Repo`, a standard Ecto/PostgreSQL
repo) and the cluster topology (`:libcluster`) are configured in
`config/config.exs` like any Elixir app. PostgreSQL is a required runtime
dependency — the node will not boot without a reachable instance. See
[Installation](install.md) for connection setup.
