defmodule Hyper.Node.FireVMM.Provider do
  @moduledoc """
  Downloads and installs the firecracker + jailer binaries for the current
  architecture into `Hyper.Config.firecracker_install_dir/0`
  (`<work_dir>/redist/firecracker`).

  `ensure_installed/1` is idempotent: if the binaries for the pinned version are
  already present and executable it returns `:ok` without touching the network.
  Otherwise it downloads the official firecracker release tarball for the
  detected architecture into a temporary directory, verifies its SHA-256 against
  a pinned digest, extracts it, copies `firecracker` and `jailer` into the
  install dir, and removes the temporary directory (always, via `try/after`).

  The checksum is pinned here on purpose: downloading the `*.sha256.txt` from the
  same host as the tarball would be trust-on-first-use and provide no real
  integrity guarantee. Pinning the digest is what makes the check meaningful.
  """

  @version "1.16.0"

  # SHA-256 of the official release tarballs, pinned per architecture. Contents
  # of firecracker-v<ver>-<arch>.tgz.sha256.txt from the GitHub release.
  @checksums %{
    "x86_64" => "bd04e26952d4e158085778c6230a0b383d2619c319182e27eaa9d61a212e92d6",
    "aarch64" => "531c713cdbc37d4b8bc2533d851aabc0267096afa1768086a37672abb668efd7"
  }

  @github_base "https://github.com/firecracker-microvm/firecracker/releases/download"

  @doc "Detect the firecracker arch string for the current machine."
  @spec target_arch() :: {:ok, String.t()} | {:error, {:unsupported_arch, String.t()}}
  def target_arch do
    sys = to_string(:erlang.system_info(:system_architecture))

    cond do
      String.contains?(sys, "x86_64") -> {:ok, "x86_64"}
      String.contains?(sys, "amd64") -> {:ok, "x86_64"}
      String.contains?(sys, "aarch64") -> {:ok, "aarch64"}
      String.contains?(sys, "arm64") -> {:ok, "aarch64"}
      true -> {:error, {:unsupported_arch, sys}}
    end
  end

  @doc "Verify the SHA-256 of `path` equals `expected` (lowercase hex)."
  @spec verify_checksum(Path.t(), String.t()) ::
          :ok | {:error, {:checksum_mismatch, String.t(), String.t()}}
  def verify_checksum(path, expected) do
    actual = sha256_file(path)

    if actual == expected do
      :ok
    else
      {:error, {:checksum_mismatch, expected, actual}}
    end
  end

  @doc "Streaming SHA-256 of a file, returned as lowercase hex."
  @spec sha256_file(Path.t()) :: String.t()
  def sha256_file(path) do
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

  @doc """
  Extract `tar_path` into a sibling `extract/` dir and copy the firecracker +
  jailer binaries into `install_dir`, writing the version marker on success.
  """
  @spec extract_and_install(Path.t(), String.t(), Path.t()) ::
          :ok
          | {:error,
             {:extract_failed, term()}
             | {:missing_binary, Path.t()}
             | {:unsafe_tar_entry, String.t()}}
  def extract_and_install(tar_path, arch, install_dir) do
    extract_dir = Path.join(Path.dirname(tar_path), "extract")
    File.mkdir_p!(extract_dir)

    case :erl_tar.table(String.to_charlist(tar_path), [:compressed]) do
      {:ok, entries} ->
        case find_unsafe_entry(entries) do
          {:unsafe, name} ->
            {:error, {:unsafe_tar_entry, name}}

          :safe ->
            case :erl_tar.extract(String.to_charlist(tar_path),
                   [:compressed, :keep_old_files, {:cwd, String.to_charlist(extract_dir)}]) do
              :ok -> install_binaries(extract_dir, arch, install_dir)
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

  defp install_binaries(extract_dir, arch, install_dir) do
    base = "release-v#{@version}-#{arch}"
    fc_src = Path.join([extract_dir, base, "firecracker-v#{@version}-#{arch}"])
    jail_src = Path.join([extract_dir, base, "jailer-v#{@version}-#{arch}"])

    with :ok <- check_exists(fc_src),
         :ok <- check_exists(jail_src) do
      File.mkdir_p!(install_dir)
      install_one(fc_src, Path.join(install_dir, "firecracker"))
      install_one(jail_src, Path.join(install_dir, "jailer"))
      File.write!(Path.join(install_dir, ".fc-version"), @version)
      :ok
    end
  end

  defp check_exists(path) do
    if File.regular?(path), do: :ok, else: {:error, {:missing_binary, path}}
  end

  defp install_one(src, dest) do
    File.cp!(src, dest)
    File.chmod!(dest, 0o755)
  end

  @doc "Whether the pinned-version binaries are already installed and executable."
  @spec installed?(Path.t()) :: boolean()
  def installed?(install_dir) do
    fc = Path.join(install_dir, "firecracker")
    jail = Path.join(install_dir, "jailer")
    marker = Path.join(install_dir, ".fc-version")

    Hyper.Sys.Posix.executable?(fc) and
      Hyper.Sys.Posix.executable?(jail) and
      File.read(marker) == {:ok, @version}
  end

  @doc """
  Ensure the firecracker + jailer binaries are installed for this node.

  Idempotent: returns `:ok` immediately if the pinned version is already
  installed. Otherwise downloads, verifies, extracts, and installs, always
  cleaning up the temporary directory.

  Options (default to production values; overridden in tests):

    * `:arch` - target architecture string (default: `target_arch/0`)
    * `:install_dir` - install location (default: `Hyper.Config.firecracker_install_dir/0`)
    * `:checksums` - `%{arch => sha256_hex}` (default: pinned `@checksums`)
    * `:fetch` - `(url, dest_path -> :ok | {:error, term})` (default: `Req`)
  """
  @spec ensure_installed(keyword()) :: :ok | {:error, term()}
  def ensure_installed(opts \\ []) do
    install_dir = Keyword.get(opts, :install_dir, Hyper.Config.firecracker_install_dir())

    with {:ok, arch} <- resolve_arch(opts) do
      if installed?(install_dir) do
        :ok
      else
        do_install(arch, install_dir, opts)
      end
    end
  end

  @doc false
  @spec tarball_url(String.t()) :: String.t()
  def tarball_url(arch) do
    "#{@github_base}/v#{@version}/firecracker-v#{@version}-#{arch}.tgz"
  end

  defp resolve_arch(opts) do
    case Keyword.fetch(opts, :arch) do
      {:ok, arch} -> {:ok, arch}
      :error -> target_arch()
    end
  end

  defp do_install(arch, install_dir, opts) do
    checksums = Keyword.get(opts, :checksums, @checksums)
    fetch = Keyword.get(opts, :fetch, &default_fetch/2)

    with {:ok, expected} <- fetch_checksum(checksums, arch) do
      tmp = make_tmp_dir!()

      try do
        tar = Path.join(tmp, "firecracker-#{arch}.tgz")

        with :ok <- fetch.(tarball_url(arch), tar),
             :ok <- verify_checksum(tar, expected),
             :ok <- extract_and_install(tar, arch, install_dir) do
          :ok
        end
      after
        File.rm_rf!(tmp)
      end
    end
  end

  defp fetch_checksum(checksums, arch) do
    case Map.fetch(checksums, arch) do
      {:ok, sha} -> {:ok, sha}
      :error -> {:error, {:unsupported_arch, arch}}
    end
  end

  defp make_tmp_dir! do
    dir = Path.join(System.tmp_dir!(), "hyper-firecracker-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  defp default_fetch(url, dest_path) do
    case Req.get(url, into: File.stream!(dest_path), redirect: true, max_redirects: 5) do
      {:ok, %Req.Response{status: 200}} -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, {:download_failed, status}}
      {:error, reason} -> {:error, {:download_error, reason}}
    end
  end
end
