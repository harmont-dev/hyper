# Configuration

Configuring `Hyper` is done through four layers, in priority:

## Configuration Files

| File                     | Description |
| ------------------------ | ----------- |
| `/etc/hyper/config.exs`  | The `config.exs` file is exlusively used by the unprivileged `hyper` application. The purpose of this file is to allow you to load configuration values at runtime. If you are using a secrets manager, this is the right place to load the secrets. Must be owned by `root` and only writeable by `root`. |
| `/etc/hyper/config.toml` | The `/etc/hyper/config.toml` file is used for static configuration. Unlike `config.exs`, it is used by both `Hyper` and `hyper-suidhelper` which means that it can impact the behavior of a process running under `root`. Must be owned by `root` and only writable by `root`. |
| Compile-Time `config.ex` | The compile-time configuration is generally used to fine-tune the performance of Hyper. You likely do not need to edit most of the configuration fields exposed by this file for day-to-day usage, but they are available for you to tweak. |
| Defaults                 | `Hyper` has a set of sane defaults for some, but not all config fields. |

**Note that not all layers allow all configuration fields to be tweaked.** Read
further for more details on where and how each configuration field is set.

# Configuration Fields

This section briefly outlines the configuration fields available in `Hyper`.
Note the keys are abbreviated for better layout:

  - `config.exs` refers to `/etc/hyper/config.exs`.
  - `config.toml` refers to `/etc/hyper/config.toml`.
  - All keys under `config.exs` are written in short-hand form. The parent
    group is given as the section title. For example, `.mke2fs` in the tool
    configuration section expands to
    `:hyper, Hyper.Cfg.Tools, mke2fs: "/path/to/mke2fs"`.

## Root Keys

| Config Key | `config.exs` | `config.toml` | Default | Notes |
| ---------- | ------------ | ------------- | ------- | ----- |
| `work_dir` | -            | `work_dir`    | -       | [Absolute Path](#absolute-path) where `Hyper` creates its working tree. |

<!-- tabs open -->
### `config.toml`

```toml
work_dir = "/srv/hyper"
```
<!-- tabs close -->

## Tool Configuration

Hyper relies on a large number of external tools, of which the paths are
configurable:

| Config Key    | `config.exs`  | `config.toml`  | Default                             | Notes |
| ------------- | ------------- | -------------- | ----------------------------------- | ----- |
| `firecracker` | -             | `.firecracker` | -                                   | [Safe Path](#safe-path) |
| `jailer`      | -             | `.jailer`      | -                                   | [Safe Path](#safe-path) |
| `dmsetup`     | -             | `.dmsetup`     | `"/usr/sbin/dmsetup"`               | [Safe Path](#safe-path) |
| `losetup`     | -             | `.losetup`     | `"/usr/sbin/losetup"`               | [Safe Path](#safe-path) |
| `blockdev`    | -             | `.blockdev`    | `"/usr/sbin/blockdev"`              | [Safe Path](#safe-path) |
| `mke2fs`      | `.mke2fs`     | `.mke2fs`      | `$PATH["mke2fs"]`                   |  |
| `skopeo`      | `.skopeo`     | `.skopeo`      | `$PATH["skopeo"]`                   |  |
| `umoci`       | `.umoci`      | `.umoci`       | Automatically downloaded.           |  |
| `suidhelper`  | `.suidhelper` | `.suidhelper`  | `"/usr/local/bin/hyper-suidhelper"` | [Absolute Path](#absolute-path) |

<!-- tabs open -->
### `config.exs`

```elixir
# Note that not all the tools are available here. Privileged tools, used by the
# suidhelper, cannot be configured here.
config :hyper, Hyper.Cfg.Tools,
  skopeo: "/usr/local/bin/skopeo",
  mke2fs: "/usr/local/bin/mke2fs",
  umoci: "/usr/local/bin/umoci",
  suidhelper: "/usr/local/bin/hyper-suidhelper"
```

### `config.toml`

```toml
[tools]
# Privileged tools -- config.toml only (shared with the suidhelper).
firecracker = "/opt/firecracker/firecracker"
jailer      = "/opt/firecracker/jailer"
dmsetup     = "/usr/sbin/dmsetup"
losetup     = "/usr/sbin/losetup"
blockdev    = "/usr/sbin/blockdev"

# Node tools -- may also be set in config.exs, which wins when both are set.
skopeo     = "/usr/local/bin/skopeo"
mke2fs     = "/usr/local/bin/mke2fs"
umoci      = "/usr/local/bin/umoci"
suidhelper = "/usr/local/bin/hyper-suidhelper"
```
<!-- tabs close -->

## Jail Confinement

| Config Key      | `config.exs` | `config.toml`    | Default   | Notes |
| --------------- | ------------ | ---------------- | --------- | ----- |
| `cgroup`        | -            | `.cgroup`        | `"hyper"` | Parent cgroup under which each VM's cgroup is nested. Each VM receives its own ephemeral cgroup which lives under the umbrella of this cgroup. |
| `uid_gid_range` | -            | `.uid_gid_range` | -         | [Range](#range) limiting the UID/GID values given to VMs. Each VM receives its own UID/GID pair, within these bounds. Must not be an existing user/group. |

<!-- tabs open -->
### `config.toml`

```toml
[jails]
cgroup = "hyper"
uid_gid_range = [900000, 999999]
```
<!-- tabs close -->

## gRPC Configuration

Hyper supports a [gRPC](https://grpc.io/) interface enabling you to interface
with `Hyper` from any language.

| Config Key     | `config.exs`    | `config.toml`   | Default | Notes |
| -------------- | --------------- | --------------- | ------- | ----- |
| `enabled`      | `.enabled`      | `.enabled`      | `false` |  |
| `port`         | `.port`         | `.port`         | `50051` | The port on which to serve the interface. |
| `cred`         | `.cred`         | `.cred`         | `nil`   | Either a `GRPC.Credential` or a TOML struct `{ cert = "/path/to/cert.pem", key = "/path/to/key.pem"}`. Cleartext mode when `nil`. |
| `adapter_opts` | `.adapter_opts` | `.adapter_opts` | `[]`    | Options forwarded to the gRPC server adapter, e.g. the bind address `ip: {0, 0, 0, 0}`. |

> #### Uniqueness {: .info}
>
> Note that if you choose to use a homogenous configuration across all your
> nodes and you enable the gRPC server on all of them, you will spawn multiple
> gRPC servers, one-per-node, in your cluster.
>
> This is perfectly legal, if you so desire, but it is important to note that
> you can also conditionally enable the `gRPC` server based on logic in your
> `config.exs`, for example, to only spawn it on your "main" server.

<!-- tabs open -->
### `config.exs`

```elixir
config :hyper, Hyper.Cfg.Grpc,
  enabled: true,
  port: 50_051,
  cred:
    GRPC.Credential.new(
      ssl: [certfile: "/etc/hyper/tls/cert.pem", keyfile: "/etc/hyper/tls/key.pem"]
    )
```

### `config.toml`

```toml
[grpc]
enabled = true
port = 50051
cred = { cert = "/etc/hyper/tls/cert.pem", key = "/etc/hyper/tls/key.pem" }
```
<!-- tabs close -->

## Telemetry Configuration

You can configure telemetry with Hyper by adding this section to your
configuration and Hyper will emit tracing spans as configured.

| Config Key | `config.exs` | `config.toml` | Default | Notes |
| ---------- | ------------ | ------------- | ------- | ----- |
| `proto`    | `.proto`     | `.proto`      | -       |  |
| `endpoint` | `.endpoint`  | `.endpoint`   | -       |  |
| `headers`  | `.headers`   | `.headers`    | -       |  |

<!-- tabs open -->
### `config.exs`

```elixir
config :hyper, Hyper.Cfg.Otel,
  proto: :http_protobuf,
  endpoint: "https://api.honeycomb.io",
  headers: %{"x-honeycomb-team" => "YOUR_API_KEY"}
```

### `config.toml`

```toml
[otel]
proto = "http_protobuf"
endpoint = "https://api.honeycomb.io"
headers = { "x-honeycomb-team" = "YOUR_API_KEY" }
```
<!-- tabs close -->

## Budget Configuration

Hyper allows you to control the absolute maximal budgets that are available to
all VMs on a particular node.

| Config Key         | `config.exs`        | `config.toml`       | Default   | Notes |
| ------------------ | ------------------- | ------------------- | --------- | ----- |
| `mem_max`          | `.mem_max`          | `.mem_max`          | -         | [$\alpha$ budget](./architecture.md#budgets) [unit](#unit) of RAM usage. This value **must not** exceed available system memory. |
| `disk_max`         | `.disk_max`         | `.disk_max`         | -         | [$\alpha$ budget](./architecture.md#budgets) [unit](#unit) of disk usage. This value **must not** exceed available system disk space. |
| `cpu_max_load`     | `.cpu_max_load`     | `.cpu_max_load`     | -         | [$\beta$ budget](./architecture.md#budgets) [unit](#unit) of CPU usage. |
| `cpu_max_cap`      | `.cpu_max_cap`      | `.cpu_max_cap`      | -         | [$\alpha$ budget](./architecture.md#budgets) [unit](#unit) of CPU usage. |
| `disk_bw_cap`      | `.disk_bw_cap`      | `.disk_bw_cap`      | -         | [$\beta$ budget](./architecture.md#budgets) [unit](#unit) of disk bandwidth. |
| `disk_bw_max_load` | `.disk_bw_max_load` | `.disk_bw_max_load` | -         | [$\alpha$ budget](./architecture.md#budgets) [unit](#unit) of disk bandwidth. |
| `net_bw_cap`       | `.net_bw_cap`       | `.net_bw_cap`       | -         | [$\beta$ budget](./architecture.md#budgets) [unit](#unit) of net bandwidth. |
| `net_bw_max_load`  | `.net_bw_max_load`  | `.net_bw_max_load`  | -         | [$\alpha$ budget](./architecture.md#budgets) [unit](#unit) of net bandwidth. |

<!-- tabs open -->
### `config.exs`

```elixir
config :hyper, Hyper.Cfg.Budget,
  mem_max: Unit.Information.gib(4),
  disk_max: Unit.Information.gib(64),
  cpu_max_load: 0.8,
  cpu_max_cap: 4.0,
  disk_bw_cap: Unit.Bandwidth.gibps(1),
  disk_bw_max_load: 0.8,
  net_bw_cap: Unit.Bandwidth.gibps(1),
  net_bw_max_load: 0.8
```

### `config.toml`

```toml
[budget]
mem_max = "4GiB"
disk_max = "64GiB"
cpu_max_load = 0.8
cpu_max_cap = 4.0
disk_bw_cap = "1GiBps"
disk_bw_max_load = 0.8
net_bw_cap = "1GiBps"
net_bw_max_load = 0.8
```
<!-- tabs close -->

## VmLinux Paths

Hyper requires Linux images for the architectures it runs on:

| Config Key | `config.exs` | `config.toml` | Default                                                                                      | Notes |
| ---------- | ------------ | ------------- | -------------------------------------------------------------------------------------------- | ----- |
| `amd64`    | `.amd64`     | `.amd64`      | Automatically downloaded from [hyper-vmlinux](https://github.com/harmont-dev/hyper-vmlinux). | [Absolute Path](#absolute-path). |
| `aarch64`  | `.aarch64`   | `.aarch64`    | Automatically downloaded from [hyper-vmlinux](https://github.com/harmont-dev/hyper-vmlinux). | [Absolute Path](#absolute-path). |

<!-- tabs open -->
### `config.exs`

```elixir
config :hyper, Hyper.Cfg.VmLinux,
  amd64: "/opt/hyper/kernels/vmlinux-amd64",
  aarch64: "/opt/hyper/kernels/vmlinux-aarch64"
```

### `config.toml`

```toml
[vmlinux]
amd64 = "/opt/hyper/kernels/vmlinux-amd64"
aarch64 = "/opt/hyper/kernels/vmlinux-aarch64"
```
<!-- tabs close -->

## Image Configuration

Hyper's image provisioning layer has a large set of configuration flags
enabling you to tweak how you want Hyper to manage images.

| Config Key | `config.exs` | `config.toml` | Default | Notes |
| ---------- | ------------ | ------------- | ------- | ----- |
| `store`    | `.store`     | `.store`      | -       | [Absolute Path](#absolute-path) to the [layer storage medium](./architecture.md#storage). |

<!-- tabs open -->
### `config.exs`

```elixir
config :hyper, Hyper.Cfg.Img,
  store: "/mnt/hyper/layers"
```

### `config.toml`

```toml
[img]
store = "/mnt/hyper/layers"
```
<!-- tabs close -->

Additionally, sub-sections are available.

### Database Configuration

| Config Key | `config.exs` | `config.toml` | Default   | Notes |
| ---------- | ------------ | ------------- | --------- | ----- |
| `database` | `.database`  | -             | `"hyper"` |  |
| `username` | `.username`  | -             | -         |  |
| `password` | `.password`  | -             | -         |  |
| `hostname` | `.hostname`  | -             | -         |  |

<!-- tabs open -->
### `config.exs`

```elixir
config :hyper, Hyper.Cfg.Img.Db,
  database: "hyper",
  username: "hyper",
  password: System.fetch_env!("HYPER_DB_PASSWORD"),
  hostname: "db.internal"
```
<!-- tabs close -->

### Garbage Collector Configuration

Hyper supports a mechanism to prune unreferenced image layers. Unreferenced
image layers occur when an ungraceful crash happens, resulting in entries in
the layer medium which are not referenced by the database, and, consequently,
unusable. This is always enabled. Since this scans through the whole layer
database, it can have an impact on performance, and tweaking it may be
necessary.

| Config Key         | `config.exs`        | `config.toml`       | Default   | Notes |
| ------------------ | ------------------- | ------------------- | --------- | ----- |
| `batch_size`       | `.batch_size`       | `.batch_size`       | `200`     |  |
| `batch_pause`      | `.batch_pause`      | `.batch_pause`      | `100ms`   |  |
| `sweep_interval`   | `.sweep_interval`   | `.sweep_interval`   | `60s`     |  |
| `acquire_interval` | `.acquire_interval` | `.acquire_interval` | `5s`      |  |
| `retry`            | `.retry`            | `.retry`            | `60s`     |  |
| `timeout`          | `.timeout`          | `.timeout`          | `5s`      |  |
| `grace_period`     | `.grace_period`     | `.grace_period`     | `1h`      |  |

<!-- tabs open -->
### `config.exs`

```elixir
config :hyper, Hyper.Cfg.Img.Gc,
  batch_size: 200,
  batch_pause: Unit.Time.ms(100),
  sweep_interval: Unit.Time.s(60),
  acquire_interval: Unit.Time.s(5),
  retry: Unit.Time.s(60),
  timeout: Unit.Time.s(5),
  grace_period: Unit.Time.s(3600)
```

### `config.toml`

```toml
[img.gc]
batch_size = 200
batch_pause = "100ms"
sweep_interval = "60s"
acquire_interval = "5s"
retry = "60s"
timeout = "5s"
grace_period = "1h"
```
<!-- tabs close -->

## Cluster Topology

<!-- TODO(markovejnovic): Write this -->

## Key Types

#### Absolute Path

  - Typed as a string in TOML and elixir.
  - Must be given as an absolute path.

#### Safe Path

  - Is an [Absolute Path](#absolute-path).
  - The basename **must** match the configuration, eg. `firecracker` must have
    a path `/foo/bar/firecracker`.
  - Must be owned by `root`.
  - Must be only writable by `root`.
  - Must not be a symlink.

#### Range

  - Typed as a 2-tuple in Elixir
  - Typed as an array of two elements in TOML.
  - `[min, max]` semantics.

#### Unit

  - Represents a unit as defined in `Unit.*`.

## Total Examples

A complete `config.exs` and `config.toml` exercising every section:

<!-- tabs open -->
### `config.exs`

```elixir
import Config

# Node-only tools (config.exs wins over config.toml for these).
config :hyper, Hyper.Cfg.Tools,
  skopeo: "/usr/local/bin/skopeo",
  mke2fs: "/usr/local/bin/mke2fs"

config :hyper, Hyper.Cfg.Grpc,
  enabled: true,
  port: 50_051

config :hyper, Hyper.Cfg.Otel,
  proto: :http_protobuf,
  endpoint: "https://api.honeycomb.io",
  headers: %{"x-honeycomb-team" => System.fetch_env!("HONEYCOMB_API_KEY")}

config :hyper, Hyper.Cfg.Budget,
  mem_max: Unit.Information.gib(4),
  disk_max: Unit.Information.gib(64),
  cpu_max_load: 0.8,
  cpu_max_cap: 4.0,
  disk_bw_cap: Unit.Bandwidth.gibps(1),
  disk_bw_max_load: 0.8,
  net_bw_cap: Unit.Bandwidth.gibps(1),
  net_bw_max_load: 0.8

config :hyper, Hyper.Cfg.Img,
  store: "/mnt/hyper/layers"

config :hyper, Hyper.Cfg.Img.Db,
  database: "hyper",
  username: "hyper",
  password: System.fetch_env!("HYPER_DB_PASSWORD"),
  hostname: "db.internal"
```

### `config.toml`

```toml
work_dir = "/srv/hyper"

[tools]
firecracker = "/opt/firecracker/firecracker"
jailer      = "/opt/firecracker/jailer"

[jails]
cgroup = "hyper"
uid_gid_range = [900000, 999999]

[grpc]
enabled = true
port = 50051

[otel]
proto = "http_protobuf"
endpoint = "https://api.honeycomb.io"

[budget]
mem_max = "4GiB"
disk_max = "64GiB"
cpu_max_load = 0.8
cpu_max_cap = 4.0
disk_bw_cap = "1GiBps"
disk_bw_max_load = 0.8
net_bw_cap = "1GiBps"
net_bw_max_load = 0.8

[vmlinux]
amd64 = "/opt/hyper/kernels/vmlinux-amd64"
aarch64 = "/opt/hyper/kernels/vmlinux-aarch64"

[img]
store = "/mnt/hyper/layers"

[img.gc]
batch_size = 200
sweep_interval = "60s"
grace_period = "1h"
```
<!-- tabs close -->
