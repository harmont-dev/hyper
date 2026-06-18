defmodule Hyper.Sys.Linux.Cgroup do
  @moduledoc "cgroup introspection."

  alias Hyper.Sys.Linux.Proc.Mounts

  @doc """
  Detect which cgroup versions are mounted on this system, from `/proc/mounts`.

    * `{:cgroup, :cgroup2}` — hybrid (v1 controllers + the v2 unified hierarchy)
    * `{:cgroup2}`          — v2 only (the modern default)
    * `{:cgroup}`           — v1 only (legacy)
    * `nil`                 — none mounted (or `/proc/mounts` unreadable)
  """
  @spec versions :: {:cgroup, :cgroup2} | {:cgroup2} | {:cgroup} | nil
  def versions do
    with {:ok, mounts} <- Mounts.list() do
      types = mounts |> Enum.map(& &1.fs_type) |> MapSet.new()

      case {MapSet.member?(types, "cgroup"), MapSet.member?(types, "cgroup2")} do
        {true, true} -> {:cgroup, :cgroup2}
        {false, true} -> {:cgroup2}
        {true, false} -> {:cgroup}
        {false, false} -> nil
      end
    else
      {:error, _} -> nil
    end
  end
end
