defmodule Sys.Linux.Proc.Mounts do
  @moduledoc "Reads the currently-mounted filesystems from `/proc/mounts`."

  alias Sys.Linux.Fstab

  @path "/proc/mounts"

  @doc "List the currently-mounted filesystems."
  @spec list :: {:ok, [Fstab.Spec.t()]} | {:error, File.posix()}
  def list do
    with {:ok, content} <- File.read(@path), do: {:ok, parse(content)}
  end

  @doc """
  Parse a `/proc/mounts` payload: one fstab-formatted line per mount. Lines
  that do not parse as fstab entries are skipped — the file is
  kernel-generated, so a malformed line is noise, not an error.
  """
  @spec parse(String.t()) :: [Fstab.Spec.t()]
  def parse(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Fstab.parse(line) do
        {:ok, spec} -> [spec]
        {:error, _} -> []
      end
    end)
  end
end
