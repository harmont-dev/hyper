defmodule Hyper.Redist.Sha256 do
  @moduledoc "Streaming SHA-256 of a file, returned as lowercase hex."

  @doc "Streaming SHA-256 of the file at `path`, as lowercase hex."
  @spec file(Path.t()) :: String.t()
  def file(path) do
    path
    |> File.open!([:read, :binary, :raw], fn io -> hash_io(io, :crypto.hash_init(:sha256)) end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  # Fold the file through the hash context in 2 MiB chunks.
  defp hash_io(io, ctx) do
    case :file.read(io, 2 * 1024 * 1024) do
      {:ok, data} -> hash_io(io, :crypto.hash_update(ctx, data))
      :eof -> ctx
    end
  end
end
