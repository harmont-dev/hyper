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

    @type linux_t :: %{
            optional(:"cpu.max") => String.t(),
            optional(:"memory.max") => String.t()
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

    @doc "Render the config into cgroup v2 interface-file => value pairs."
    @spec as_linux(t()) :: linux_t()
    def as_linux(cfg) do
      Map.new(cfg, fn
        {:cpu_max, %{quota_us: quota, period_us: period}} -> {:"cpu.max", "#{quota} #{period}"}
        {:memory_max, bytes} -> {:"memory.max", to_string(bytes)}
      end)
    end
  end
end
