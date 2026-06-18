defmodule Hyper.Sys.Linux.Cgroup.V2 do
  @moduledoc "cgroup v2 (unified hierarchy) helpers."

  @doc "Check whether the given named cgroup exists or not."
  @spec named_exists?(Path.t()) :: boolean()
  def named_exists?(name) do
    File.dir?("/sys/fs/cgroup/#{name}")
  end

  defmodule Config do
    @moduledoc "Map which represents the possible configurations of a cgroup"

    @type cpu_spec :: %{
            required(:quota_us) => pos_integer(),
            required(:period_us) => pos_integer()
          }

    @type t :: %{
            optional(:cpu_max) => cpu_spec(),
            optional(:memory_max) => pos_integer()
          }

    @spec new :: t()
    def new do
      %{}
    end

    @spec cpu_max(t(), pos_integer(), pos_integer()) :: t()
    def cpu_max(cfg, quota_us, period_us) do
      Map.put(cfg, :cpu_max, %{quota_us: quota_us, period_us: period_us})
    end

    @spec memory_max(t(), pos_integer()) :: t()
    def memory_max(cfg, val), do: Map.put(cfg, :memory_max, val)
  end
end
