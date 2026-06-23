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

### Storage backends

`Hyper` keeps its image graph (blobs, images, image-layers, leases) in a
metadata database via `Hyper.Img.Db.Repo`. Two backends are available, chosen
in your config:

```elixir
# cluster-safe default; required for any multi-node deployment
config :hyper, Hyper.Img.Db, backend: :postgres

# single-node deployments only
config :hyper, Hyper.Img.Db, backend: :sqlite
```

Connection settings live under `config :hyper, Hyper.Img.Db.Repo`. For Postgres
that is the usual `database`/`username`/`password`/`hostname`. For SQLite,
point it at a file and use the SQLite adapter options, e.g.:

```elixir
config :hyper, Hyper.Img.Db, backend: :sqlite

config :hyper, Hyper.Img.Db.Repo,
  database: "/srv/hyper/hyper.db",
  pool_size: 1,
  journal_mode: :wal,
  busy_timeout: 5_000,
  binary_id_type: :string,
  datetime_type: :iso8601
```

The backend is resolved at compile time, so changing it takes effect on the
next build. Apply migrations the same way for either backend:

```sh
mix ecto.migrate
```

> #### SQLite is single-node only
>
> SQLite is a single-writer file database and **must not** be shared across
> cluster nodes. When the SQLite backend is configured, `Hyper` starts
> `Hyper.SingleNodeGuard`, which refuses to boot if peers are already connected
> and halts the node (via `System.stop/1`) if a peer joins later -- protecting
> the file from the concurrent writers that would corrupt it.
>
> One behavioural caveat: under SQLite, an `ON CONFLICT DO UPDATE` upsert
> returns a struct carrying a freshly-generated UUID rather than the stored
> row's `id`. `Hyper.Img.Db.Lease.bump/3` is the only such upsert and its
> callers don't read the returned `id`, so there is no live bug -- but use
> Postgres if you need reliable round-trip identity on bumped leases.
