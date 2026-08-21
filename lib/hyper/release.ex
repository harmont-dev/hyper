defmodule Hyper.Release do
  @moduledoc """
  Release-time tasks, callable from an assembled release with `bin/hyper eval`.

  A release has no Mix, so `mix ecto.migrate` is unavailable on a deployed node.
  These entry points drive `Ecto.Migrator` directly against the repos declared in
  the app's `:ecto_repos` env, after loading (not starting) the application so the
  env — including anything `HYPER_CONFIG` contributed — is readable:

      bin/hyper eval "Hyper.Release.migrate()"
  """

  @app :hyper

  @doc """
  Runs all pending migrations for every configured repo. Idempotent.
  """
  @spec migrate() :: :ok
  def migrate do
    load_app()

    Enum.each(repos(), fn repo ->
      {:ok, _result, _apps} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end)
  end

  @doc """
  Rolls `repo` back to `version`.
  """
  @spec rollback(module(), integer()) :: :ok
  def rollback(repo, version) do
    load_app()

    {:ok, _result, _apps} =
      Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))

    :ok
  end

  @spec repos() :: [module()]
  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  @spec load_app() :: :ok
  defp load_app do
    # Already-loaded is the normal case under `bin/hyper eval`, which loads the
    # release's applications before evaluating.
    _ = Application.load(@app)
    :ok
  end
end
