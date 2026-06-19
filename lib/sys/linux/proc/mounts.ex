defmodule Sys.Linux.Proc.Mounts do
  @moduledoc "Reads the currently-mounted filesystems from `/proc/mounts`."

  alias Sys.Linux.Fstab

  @path "/proc/mounts"

  @doc "List the currently-mounted filesystems."
  @spec list :: {:ok, [Fstab.Spec.t()]} | {:error, File.posix()}
  def list do
    with {:ok, content} <- File.read(@path) do
      specs =
        content
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case Fstab.parse(line) do
            {:ok, spec} -> [spec]
            {:error, _} -> []
          end
        end)

      {:ok, specs}
    end
  end
end
