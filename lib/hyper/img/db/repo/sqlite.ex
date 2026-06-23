defmodule Hyper.Img.Db.Repo.Sqlite do
  @moduledoc """
  SQLite-backed image-graph repository.

  Single-node only: a single-writer file database cannot be shared safely
  across cluster nodes. `Hyper.Img.Db.SingleNodeGuard` enforces this at
  runtime. Reached through the `Hyper.Img.Db.Repo` facade.

  Shares the `priv/repo/migrations` directory with the Postgres repo; the
  image-graph DDL contains no Postgres-specific constructs.
  """

  use Ecto.Repo,
    otp_app: :hyper,
    adapter: Ecto.Adapters.SQLite3,
    priv: "priv/repo",
    telemetry_prefix: [:hyper, :img, :db, :repo]
end
