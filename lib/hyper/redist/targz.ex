defmodule Hyper.Redist.Targz do
  @moduledoc """
  Fetches a gzipped tarball from a URL, verifies its SHA-256, and extracts it
  into a directory.
  """

  alias Redist.Sha256

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
    Sys.Tmp.with_tempdir("hyper-redist", fn tmp ->
      tar = Path.join(tmp, "download.tar.gz")

      with :ok <- fetch(url, tar),
           :ok <- verify_checksum(tar, sha256) do
        extract(tar, dest_dir)
      end
    end)
  end

  defp verify_checksum(path, expected) do
    actual = Sha256.file(path)
    if actual == expected, do: :ok, else: {:error, {:checksum_mismatch, expected, actual}}
  end

  defp extract(tar_path, dest_dir) do
    File.mkdir_p!(dest_dir)

    case :erl_tar.extract(
           String.to_charlist(tar_path),
           [:compressed, :keep_old_files, {:cwd, String.to_charlist(dest_dir)}]
         ) do
      :ok -> :ok
      {:error, {name, :unsafe_path}} -> {:error, {:unsafe_tar_entry, to_string(name)}}
      {:error, reason} -> {:error, {:extract_failed, reason}}
    end
  end

  defp fetch(url, dest_path) do
    case Req.get(url, into: File.stream!(dest_path), redirect: true, max_redirects: 5) do
      {:ok, %Req.Response{status: 200}} -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, {:download_failed, status}}
      {:error, reason} -> {:error, {:download_error, reason}}
    end
  end
end
