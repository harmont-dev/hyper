defmodule Hyper.Redist.Targz do
  @moduledoc """
  Fetches a gzipped tarball from a URL, verifies its SHA-256, and extracts it
  into a directory.
  """

  @doc """
  Download `url`, verify its SHA-256 equals `sha256` (lowercase hex), and extract
  the archive into `dest_dir`.
  """
  @spec install(String.t(), String.t(), Path.t()) ::
          :ok
          | {:error,
             {:download_failed, non_neg_integer()}
             | {:download_error, term()}
             | {:checksum_mismatch, String.t(), String.t()}
             | {:unsafe_tar_entry, String.t()}
             | {:extract_failed, term()}}
  def install(url, sha256, dest_dir) do
    Hyper.Sys.Tmp.with_tempdir("hyper-redist", fn tmp ->
      tar = Path.join(tmp, "download.tar.gz")

      with :ok <- fetch(url, tar),
           :ok <- verify_checksum(tar, sha256),
           :ok <- extract(tar, dest_dir) do
        :ok
      end
    end)
  end

  defp verify_checksum(path, expected) do
    actual = sha256_file(path)
    if actual == expected, do: :ok, else: {:error, {:checksum_mismatch, expected, actual}}
  end

  # Streaming SHA-256 of a file, returned as lowercase hex.
  defp sha256_file(path) do
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

  defp extract(tar_path, dest_dir) do
    File.mkdir_p!(dest_dir)

    case :erl_tar.table(String.to_charlist(tar_path), [:compressed]) do
      {:ok, entries} ->
        case find_unsafe_entry(entries) do
          {:unsafe, name} ->
            {:error, {:unsafe_tar_entry, name}}

          :safe ->
            case :erl_tar.extract(
                   String.to_charlist(tar_path),
                   [:compressed, :keep_old_files, {:cwd, String.to_charlist(dest_dir)}]
                 ) do
              :ok -> :ok
              {:error, reason} -> {:error, {:extract_failed, reason}}
            end
        end

      {:error, reason} ->
        {:error, {:extract_failed, reason}}
    end
  end

  defp find_unsafe_entry(entries) do
    Enum.reduce_while(entries, :safe, fn entry, _acc ->
      name = to_string(entry)

      if String.starts_with?(name, "/") or ".." in Path.split(name) do
        {:halt, {:unsafe, name}}
      else
        {:cont, :safe}
      end
    end)
  end

  defp fetch(url, dest_path) do
    case Req.get(url, into: File.stream!(dest_path), redirect: true, max_redirects: 5) do
      {:ok, %Req.Response{status: 200}} -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, {:download_failed, status}}
      {:error, reason} -> {:error, {:download_error, reason}}
    end
  end
end
