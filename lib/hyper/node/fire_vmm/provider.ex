defmodule Hyper.Node.FireVMM.Provider do
  @moduledoc """
  Installs the firecracker release for the current architecture into
  `Hyper.Config.firecracker_install_dir/0` (`<work_dir>/redist/firecracker`).

  `ensure_installed/0` is idempotent: if the pinned version is already present
  and executable it returns `:ok` without touching the network. Otherwise it
  fetches the official firecracker release tarball for the detected architecture
  via `Hyper.Redist.Targz` (download, SHA-256 verify, extract) and writes a
  version marker. The archive is extracted as-is — the binaries live under
  `release-v<ver>-<arch>/` exactly as firecracker ships them, and
  `firecracker_bin/0` / `jailer_bin/0` resolve those paths.

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

  @doc "Absolute path to the installed firecracker binary."
  @spec firecracker_bin() :: Path.t()
  def firecracker_bin, do: release_bin("firecracker", arch!())

  @doc "Absolute path to the installed jailer binary."
  @spec jailer_bin() :: Path.t()
  def jailer_bin, do: release_bin("jailer", arch!())

  @doc """
  Ensure the firecracker release is installed for this node.

  Idempotent: returns `:ok` immediately if the pinned version is already
  installed, otherwise fetches and installs it. Quits early with
  `{:error, {:unsupported_arch, _}}` if this machine's architecture is not
  supported.
  """
  @spec ensure_installed() :: :ok | {:error, term()}
  def ensure_installed do
    with {:ok, arch} <- Hyper.Sys.Arch.current() do
      if installed?(arch), do: :ok, else: do_install(arch)
    end
  end

  @doc false
  @spec tarball_url(Hyper.Sys.Arch.t()) :: String.t()
  def tarball_url(arch) do
    "#{@github_base}/v#{@version}/firecracker-v#{@version}-#{arch}.tgz"
  end

  # Whether the pinned-version binaries for `arch` are installed and executable.
  defp installed?(arch) do
    marker = Path.join(Hyper.Config.firecracker_install_dir(), ".fc-version")

    Hyper.Sys.Posix.executable?(release_bin("firecracker", arch)) and
      Hyper.Sys.Posix.executable?(release_bin("jailer", arch)) and
      File.read(marker) == {:ok, @version}
  end

  defp do_install(arch) do
    install_dir = Hyper.Config.firecracker_install_dir()

    with {:ok, sha} <- checksum(arch),
         :ok <- Targz.install(tarball_url(arch), sha, install_dir) do
      File.write!(Path.join(install_dir, ".fc-version"), @version)
      :ok
    end
  end

  defp checksum(arch) do
    case Map.fetch(@checksums, arch) do
      {:ok, sha} -> {:ok, sha}
      :error -> {:error, {:unsupported_arch, arch}}
    end
  end

  # Path of a named binary inside the extracted release tree.
  defp release_bin(name, arch) do
    Path.join([
      Hyper.Config.firecracker_install_dir(),
      "release-v#{@version}-#{arch}",
      "#{name}-v#{@version}-#{arch}"
    ])
  end

  defp arch! do
    case Hyper.Sys.Arch.current() do
      {:ok, arch} -> arch
      {:error, reason} -> raise ArgumentError, "unsupported architecture: #{inspect(reason)}"
    end
  end
end
