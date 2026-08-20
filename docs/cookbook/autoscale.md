# Autoscaling

This document walks through Hyper's auto-provisioning topology: a small,
always-on **control plane** that schedules work, plus **worker** nodes that are
provisioned on demand as real Firecracker hosts and torn back down. If you have
only ever run the single-node install from the [install guide](install.md),
read that first — this guide extends it, it does not replace it.

## The model

Hyper splits a deployment into two roles that share one Postgres database:

| Role       | Runs                                              | Needs KVM / Firecracker / suidhelper? |
|------------|---------------------------------------------------|:-------------------------------------:|
| `client`   | Control plane: gRPC front door, scheduler, autoscaler | **No** |
| `worker`   | A full Firecracker host: `Hyper.Node` + microVMs  | **Yes** |

- The **client** is a long-lived, always-on node. It terminates the gRPC API,
  runs the cluster scheduler, and runs the autoscaler. It never boots a VM, so
  it does **not** preflight KVM, Firecracker, the setuid helper, or networking —
  it can run on a plain VM or container with no `/dev/kvm`.
- **Workers** are provisioned automatically on [Latitude](https://www.latitude.sh/)
  bare metal. Each is a complete Firecracker host set up exactly as the
  [install guide](install.md) describes, and each joins the cluster as an
  additional VM runner. The autoscaler creates and (eventually) reclaims them.
- Both roles connect to the **same managed Postgres**. It is the image database,
  and — new in this topology — the cluster's membership registry (see
  [Dynamic clustering](#dynamic-clustering)).

The division is enforced in the supervision tree: on a `:worker`,
`Hyper.Application` starts `Hyper.Node` (which runs the KVM/Firecracker/networking
preflight); on a `:client` it starts neither `Hyper.Node` nor that preflight,
and instead starts `Hyper.Autoscale`. Both roles always start `Hyper.Cluster`
(the routing + budget CRDTs) — a client needs those registries to read peer
state and schedule onto workers.

## Choosing a role

Role is set once per node, in `/etc/hyper/config.toml`:

```toml
# "worker" (default) or "client".
role = "worker"
```

If `role` is omitted, the node is a **worker** — so an existing single-node
install keeps behaving exactly as before.

### The client config

Because a client never starts `Hyper.Node`, it never runs the Firecracker
preflight, and so it **omits** the tables that preflight requires:

```toml
role = "client"

work_dir = "/srv/hyper"

# No [tools] table    — a client runs no firecracker/jailer/suidhelper.
# No [network] table  — a client NATs no guest egress.
# No [jails] table    — a client spawns no VM jails.
```

> #### Client requirements {: .info}
>
> A client still needs its database credentials (the image DB / cluster
> registry) and a reachable Postgres. It needs no KVM, no `dm-thin`, no
> `iproute2`/`nftables`, and no setuid helper. The build toolchain requirements
> from the install guide still apply if you compile on the box, but a client
> normally runs from the same [prebuilt release](#how-a-worker-boots) as the
> workers.

> #### A worker still needs the full install {: .warning}
>
> Setting `role = "worker"` changes nothing about a worker's host
> requirements. Every worker is a complete Firecracker host and must satisfy
> **all** the hard requirements and host setup in the [install guide](install.md):
> KVM, cgroups v2, the device-mapper modules, `[tools]`, `[network]`, `[jails]`,
> and a setuid-root `hyper-suidhelper`. Auto-provisioning simply automates that
> setup via [user-data](#how-a-worker-boots); it does not remove it.

## Dynamic clustering

The single-node and static examples form the BEAM cluster from a fixed host
list (`Cluster.Strategy.Epmd` in `config/config.exs`). That does not work when
workers come and go — you cannot enumerate hosts that do not exist yet.

Instead, every node **self-registers** in a `cluster_nodes` table in the shared
Postgres on boot, and libcluster's `Hyper.Cluster.Strategy.Postgres` polls that
table and connects the mesh. There is no static host list: a freshly
provisioned worker inserts its row, the strategy sees it, and the BEAM cluster
converges. Configure it in place of the Epmd strategy:

```elixir
config :hyper, Hyper.Cfg.Cluster,
  topologies: [
    hyper: [
      strategy: Hyper.Cluster.Strategy.Postgres
    ]
  ]
```

For this to work the BEAM must be **distributed** and every node must share one
Erlang cookie. In a release, set:

```sh
export RELEASE_DISTRIBUTION=name
export RELEASE_NODE="hyper@<this-node-ip>"
export RELEASE_COOKIE="<a-shared-secret>"
```

> #### The cookie must match everywhere {: .error}
>
> Distributed Erlang authenticates peers by a shared secret cookie. **Every**
> node — the client and every worker — must boot with the *same*
> `RELEASE_COOKIE`, or the mesh silently refuses to connect and the scheduler
> sees no workers. The autoscaler injects this same cookie into each worker it
> provisions (see [`[autoscale.bootstrap]`](#autoscaler-configuration)).

> #### Node names must be routable {: .warning}
>
> `RELEASE_NODE` must be `hyper@<ip>` with an IP the other nodes can actually
> reach. Because workers live on public Latitude metal, this is typically the
> worker's public IP. The `cluster_nodes` row a node registers carries this
> name — if it is not routable from the client, the CRDT registries never sync.

## Autoscaler configuration

The autoscaler runs only on the client, and only when enabled. It is configured
by an `[autoscale]` table (plus nested tables) in `/etc/hyper/config.toml`.

```toml
role = "client"

[autoscale]
# Master switch. When false, Hyper.Autoscale is not started at all.
enabled = true
# The warm pool: how many workers to keep running at all times.
min_nodes = 1
# Hard ceiling. The autoscaler never provisions past this many workers.
max_nodes = 4

# Where and how to provision bare metal on Latitude.
[autoscale.latitude]
project          = "proj_xxxxxxxx"
plan             = "c2-small-x86"
operating_system = "ubuntu_22_04_x64_lts"
site             = "SAO"
ssh_keys         = ["ssh_key_xxxxxxxx"]
billing          = "hourly"

# What a freshly provisioned worker needs in order to boot Hyper and join.
[autoscale.bootstrap]
# The prebuilt release tarball a worker downloads and unpacks.
release_url = "https://github.com/harmont-dev/hyper/releases/download/v0.1.0/hyper-v0.1.0-x86_64-linux.tar.gz"
# The shared managed Postgres, reachable from public workers.
pg_url      = "postgres://hyper:secret@db.example.com:5432/hyper"
# The shared Erlang cookie — MUST match the client's RELEASE_COOKIE.
cookie      = "a-shared-secret"
# DNS resolver the worker's guests NAT toward.
resolver    = "1.1.1.1"
```

The Latitude API token is **not** stored in the config file — it is read from
the environment:

```sh
export LATITUDE_API_TOKEN="<your-latitude-api-token>"
```

> #### Keep secrets out of the config file {: .warning}
>
> `LATITUDE_API_TOKEN` is an environment variable, not a TOML key, so it never
> lands in `/etc/hyper/config.toml`. Note, however, that `[autoscale.bootstrap]`
> *does* contain the Postgres URL and the Erlang cookie — see
> [Security / demo caveats](#security--demo-caveats) for why that matters.

## Warm pool and reactive burst

The autoscaler's behaviour in this version is deliberately small and easy to
reason about:

- **Warm pool.** It keeps `min_nodes` workers provisioned and joined at all
  times. On startup, if fewer than `min_nodes` workers are present, it
  provisions the difference.
- **Reactive burst.** When the scheduler cannot place a VM — a run returns
  `{:error, :no_capacity}` because every worker refused — the autoscaler
  provisions **one** additional worker (up to `max_nodes`). This is reactive,
  not predictive: a burst happens in response to an actual placement failure,
  not a forecast.

> #### Scale-down is a no-op in v1 {: .warning}
>
> This version never removes a worker. Once burst past `min_nodes`, the extra
> workers stay up until you reclaim them by hand (delete the server in Latitude;
> its `cluster_nodes` row and the mesh follow). Plan your `max_nodes` ceiling and
> your Latitude bill accordingly — an idle burst worker keeps billing until you
> tear it down.

> #### Burst is one node at a time {: .info}
>
> A single `:no_capacity` provisions a single worker. A large, sudden demand
> spike is absorbed one worker per failed placement, bounded by `max_nodes` —
> combined with [provisioning latency](#security--demo-caveats), do not expect
> instant capacity.

## How a worker boots

Workers are provisioned from a **prebuilt release tarball**, not compiled on the
box. The flow is:

1. **The release is built ahead of time.** The `release-tarball` GitHub workflow
   runs on a git tag and produces the self-contained release tarball referenced
   by `[autoscale.bootstrap] release_url`. Cutting a release is what makes a new
   worker image available.
2. **The autoscaler creates a Latitude server** in the configured
   `project` / `plan` / `site`, passing a rendered **user-data** script.
3. **User-data bootstraps the host.** The template lives at
   [`priv/deploy/latitude/user-data.sh.eex`](../../priv/deploy/latitude/user-data.sh.eex).
   It is rendered with the `[autoscale.bootstrap]` values (release URL, Postgres
   URL, cookie, resolver) and Latitude runs it on first boot: it performs the
   [install guide](install.md) host setup, downloads and unpacks the release
   tarball, writes `/etc/hyper/config.toml` with `role = "worker"`, exports
   `RELEASE_DISTRIBUTION=name`, `RELEASE_NODE=hyper@<public-ip>`, and the shared
   `RELEASE_COOKIE`, then starts the release.
4. **The worker self-registers and joins.** On start it inserts its
   `cluster_nodes` row; `Hyper.Cluster.Strategy.Postgres` on the client connects
   the mesh, and the new worker becomes a schedulable VM runner.

> #### Release and running node must be the same build {: .warning}
>
> As in the install guide, a worker's setuid helper is checked against the exact
> build that produced it (BLAKE3 identity). Because the whole worker comes from
> one release tarball, this holds by construction — but it is another reason a
> worker must run the release named in `release_url`, not a hand-mixed tree.

## Security / demo caveats

This topology is aimed at a demonstrable, hands-off autoscaling story. Several
of its trade-offs are acceptable for a demo but are **not** production hardening —
read these before pointing it at anything you care about.

> #### The Erlang cookie travels in plaintext user-data {: .error}
>
> `[autoscale.bootstrap] cookie` is rendered into the Latitude user-data script
> in cleartext. Latitude user-data is not a secret store; anyone who can read a
> server's metadata can read the cluster cookie, and the cookie is the *only*
> thing authenticating a node into the distributed-Erlang mesh. Treat the cookie
> as compromised-on-provision and scope the deployment accordingly.

> #### Postgres must be reachable from public workers {: .error}
>
> Workers live on public Latitude metal and connect to the shared managed
> Postgres over the public internet (`[autoscale.bootstrap] pg_url`). That means
> Postgres must accept connections from those public IPs. Lock it down with an
> **IP allowlist** and TLS — do not leave it open to the world — and remember
> that the worker fleet's addresses change as nodes come and go.

> #### Scale-down is manual {: .warning}
>
> As stated above, v1 never reclaims a worker. Burst capacity — and its bill —
> persists until an operator deletes the server in Latitude by hand.

> #### Provisioning latency is minutes {: .warning}
>
> Bare-metal provisioning plus first-boot user-data (host setup, tarball
> download, release start, cluster join) takes **minutes**, not seconds. The
> reactive burst on `:no_capacity` is not a fast path — keep `min_nodes` high
> enough that steady-state demand is served from the warm pool, and treat burst
> as a slow safety valve rather than instant elasticity.
