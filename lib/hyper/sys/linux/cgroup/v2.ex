defmodule Hyper.Sys.Linux.Cgroup.V2 do
  @doc "Check whether the given named cgroup exists or not."
  @spec named_exists?(Path.t()) :: boolean()
  def named_exists?(name) do
    File.dir?("/sys/fs/cgroup/#{name}")
  end
end
