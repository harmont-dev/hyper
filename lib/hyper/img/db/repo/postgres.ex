defmodule Hyper.Img.Db.Repo.Postgres do
  @moduledoc """
  Postgres-backed image-graph repository.

  The cluster-safe default. Reached through the `Hyper.Img.Db.Repo` facade;
  not called directly by application code.
  """

  use Ecto.Repo,
    otp_app: :hyper,
    adapter: Ecto.Adapters.Postgres
end
