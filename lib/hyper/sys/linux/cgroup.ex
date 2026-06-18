defmodule Hyper.Sys.Linux.Cgroup do
  @moduledoc "cgroup introspection."

  alias Hyper.Sys.Linux.Proc.Mounts

  @doc """
  Detect which cgroup versions are mounted on this system, from `/proc/mounts`.

  Returns a set of the mounted versions — `:cgroup` (v1) and/or `:cgroup2` (v2).
  An empty set means none are mounted; a set with both means a hybrid hierarchy.
  """
  @spec versions :: {:ok, MapSet.t(:cgroup | :cgroup2)} | {:error, atom()}
  def versions do
    case Mounts.list() do
      {:ok, mounts} ->
        versions =
          for %{fs_type: fs} <- mounts, fs in ~w(cgroup cgroup2), into: MapSet.new() do
            String.to_existing_atom(fs)
          end

        {:ok, versions}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
