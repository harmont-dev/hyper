defmodule Hyper.Http.Server.Health do
  @moduledoc """
    Health checks module. `live/0` only proves a simple health endpoint check.
    `ready/0` checks if the system's components are ready to do useful work
  """

  @timeout_limit 1_000

  @spec ready() :: {:ok | :error, %{:atom => String.t()}}
  def ready do
    db_and_cluster_checks = checks()

    tasks =
      Enum.map(db_and_cluster_checks, fn {_name, fun} -> Task.async(fn -> safe(fun) end) end)

    results =
      db_and_cluster_checks
      |> Enum.zip(Task.yield_many(tasks, @timeout_limit))
      |> Enum.map(fn
        {{name, _}, {_task, {:ok, :up}}} ->
          {name, :up}

        {{name, _}, {task, nil}} ->
          Task.shutdown(task, :brutal_kill)
          {name, :down}

        {{name, _}, _} ->
          {name, :down}
      end)

    status = if Enum.all?(results, &match?({_, :up}, &1)), do: :ok, else: :error
    {status, Map.new(results, fn {name, r} -> {name, Atom.to_string(r)} end)}
  end

  defp checks, do: [database: &database_up?/0, cluster: &cluster_active?/0]

  defp database_up? do
    case Hyper.Img.Db.Repo.query("SELECT 1", [], timeout: @timeout_limit) do
      {:ok, _} -> :up
      {:error, _} -> :down
    end
  end

  defp cluster_active? do
    safe(fn ->
      alive =
        Process.whereis(Hyper.Cluster) != nil and
          is_pid(Process.whereis(Hyper.Cluster.Routing.name())) and
          is_pid(Process.whereis(Hyper.Cluster.Budget.name()))

      if alive and is_list(Hyper.Cluster.Routing.all()) and
           is_list(Hyper.Cluster.Budget.all_states()), do: :up, else: :down
    end)
  end

  defp safe(fun) do
    fun.()
  rescue
    _ -> :down
  catch
    _, _ -> :down
  end
end
