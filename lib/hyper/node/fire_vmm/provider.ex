defmodule Hyper.Node.FireVMM.Provider do
  @moduledoc """
  Installs the firecracker + jailer binaries for the current architecture into
  `Hyper.Config.firecracker_install_dir/0` (`<work_dir>/redist/firecracker`).

  `ensure_installed/1` is idempotent: if the binaries for the pinned version are
  already present and executable it returns `:ok` without touching the network.
  Otherwise it fetches the official firecracker release tarball for the detected
  architecture via `Hyper.Redist.Targz` (download, SHA-256 verify, extract) and
  copies `firecracker` and `jailer` out of the archive into the install dir.

  The per-architecture SHA-256 digests are pinned here on purpose: downloading
  the `*.sha256.txt` from the same host as the tarball would be trust-on-first
  -use and provide no real integrity guarantee. Pinning is what makes the check
  meaningful.
  """

  alias Hyper.Redist.Targz

  @version "1.16.0"

  # SHA-256 of the official release tarballs, pinned per architecture. Contents
  # of firecracker-v<ver>-<arch>.tgz.sha256.txt from the GitHub release.
  @checksums %{
    x86_64: "bd04e26952d4e158085778c6230a0b383d2619c319182e27eaa9d61a212e92d6",
    aarch64: "531c713cdbc37d4b8bc2533d851aabc0267096afa1768086a37672abb668efd7"
  }

  @github_base "https://github.com/firecracker-microvm/firecracker/releases/download"

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
  installed. Otherwise fetches and installs it.

  Options (default to production values; overridden in tests):

    * `:arch` - target architecture atom (default: `Hyper.Sys.Arch.current/0`)
    * `:install_dir` - install location (default: `Hyper.Config.firecracker_install_dir/0`)
    * `:checksums` - `%{arch => sha256_hex}` (default: pinned `@checksums`)
    * `:fetch` - a `(url, dest_path -> :ok | {:error, term})` downloader passed
      through to `Hyper.Redist.Targz` (default: `Req`)
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
  @spec tarball_url(Hyper.Sys.Arch.t()) :: String.t()
  def tarball_url(arch) do
    "#{@github_base}/v#{@version}/firecracker-v#{@version}-#{arch}.tgz"
  end

  defp resolve_arch(opts) do
    case Keyword.fetch(opts, :arch) do
      {:ok, arch} -> {:ok, arch}
      :error -> Hyper.Sys.Arch.current()
    end
  end

  defp do_install(arch, install_dir, opts) do
    checksums = Keyword.get(opts, :checksums, @checksums)
    targz_opts = Keyword.take(opts, [:fetch])

    with {:ok, sha} <- fetch_checksum(checksums, arch) do
      scratch = make_tmp_dir!()

      try do
        with :ok <- Targz.install(tarball_url(arch), sha, scratch, targz_opts) do
          install_binaries(scratch, arch, install_dir)
        end
      after
        File.rm_rf!(scratch)
      end
    end
  end

  defp fetch_checksum(checksums, arch) do
    case Map.fetch(checksums, arch) do
      {:ok, sha} -> {:ok, sha}
      :error -> {:error, {:unsupported_arch, arch}}
    end
  end

  # Copy the firecracker + jailer binaries out of the extracted release tree into
  # `install_dir` under stable names, then write the version marker.
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

  defp make_tmp_dir! do
    dir = Path.join(System.tmp_dir!(), "hyper-firecracker-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end
end
