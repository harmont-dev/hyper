defmodule Redist.File do
  @moduledoc """
  Fetches a single raw file from a URL, verifies its SHA-256, and installs it at
  a destination path. The raw-file analogue of `Redist.Targz` (used for
  assets that ship as plain files rather than tarballs, e.g. vmlinux images).
  """

  alias Redist.Sha256

  @doc """
  Download `url`, verify its SHA-256 equals `sha256` (lowercase hex), and install
  the file at `dest_path` (creating parent directories). The download lands in a
  temp dir first, so a failed verify never leaves a partial file at `dest_path`.
  """
  @spec install(String.t(), String.t(), Path.t()) ::
          :ok
          | {:error,
             {:download_failed, non_neg_integer()}
             | {:download_error, term()}
             | {:checksum_mismatch, String.t(), String.t()}
             | {:install_failed, term()}}
  def install(url, sha256, dest_path) do
    Sys.Tmp.with_tempdir("hyper-redist", fn tmp ->
      tmp_file = Path.join(tmp, "download")

      with :ok <- fetch(url, tmp_file),
           :ok <- verify_checksum(tmp_file, sha256) do
        place(tmp_file, dest_path)
      end
    end)
  end

  defp verify_checksum(path, expected) do
    actual = Sha256.file(path)
    if actual == expected, do: :ok, else: {:error, {:checksum_mismatch, expected, actual}}
  end

  defp place(src, dest) do
    File.mkdir_p!(Path.dirname(dest))

    case File.cp(src, dest) do
      :ok -> :ok
      {:error, reason} -> {:error, {:install_failed, reason}}
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
