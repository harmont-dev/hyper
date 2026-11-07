defmodule Sys.Linux.Dm do
  @moduledoc false

  @block "/sys/class/block"

  @spec names() :: {:ok, [String.t()]} | {:error, File.posix()}
  def names do
    with {:ok, entries} <- File.ls(@block) do
      {:ok, for("dm-" <> _ = dev <- entries, {:ok, name} <- [read_name(dev)], do: name)}
    end
  end

  @spec missing_modules([String.t()]) :: [String.t()]
  def missing_modules(modules) do
    Enum.reject(modules, &File.dir?(Path.join("/sys/module", &1)))
  end

  @spec read_name(String.t()) :: {:ok, String.t()} | {:error, File.posix()}
  defp read_name(dev) do
    with {:ok, name} <- File.read(Path.join([@block, dev, "dm", "name"])) do
      {:ok, String.trim_trailing(name, "\n")}
    end
  end
end
