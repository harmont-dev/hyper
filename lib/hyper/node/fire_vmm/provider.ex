defmodule Hyper.Node.FireVMM.Provider do
  @moduledoc """
  Installs the firecracker release for the current architecture into
  `Hyper.Config.firecracker_install_dir/0` (`<work_dir>/redist/firecracker`).

  `ensure_installed/0` is idempotent: if the binaries are already present and
  executable it returns `:ok` without touching the network. Otherwise it fetches
  the official firecracker release tarball for the detected architecture via
  `Hyper.Redist.Targz` (download, SHA-256 verify, extract). The archive is
  extracted as-is - the binaries live under `release-v<ver>-<arch>/` exactly as
  firecracker ships them, and `firecracker_bin/0` / `jailer_bin/0` resolve those
  paths.
  """

  alias Hyper.Redist.Targz

  @downloads %{
    x86_64: %{
      url:
        "https://github.com/firecracker-microvm/firecracker/releases/download/v1.16.0/firecracker-v1.16.0-x86_64.tgz",
      sha256: "bd04e26952d4e158085778c6230a0b383d2619c319182e27eaa9d61a212e92d6",
      firecracker: "release-v1.16.0-x86_64/firecracker-v1.16.0-x86_64",
      jailer: "release-v1.16.0-x86_64/jailer-v1.16.0-x86_64"
    },
    aarch64: %{
      url:
        "https://github.com/firecracker-microvm/firecracker/releases/download/v1.16.0/firecracker-v1.16.0-aarch64.tgz",
      sha256: "531c713cdbc37d4b8bc2533d851aabc0267096afa1768086a37672abb668efd7",
      firecracker: "release-v1.16.0-aarch64/firecracker-v1.16.0-aarch64",
      jailer: "release-v1.16.0-aarch64/jailer-v1.16.0-aarch64"
    }
  }

  @doc "Absolute path to the installed firecracker binary."
  @spec firecracker_bin() :: Path.t()
  def firecracker_bin, do: bin_path(:firecracker)

  @doc "Absolute path to the installed jailer binary."
  @spec jailer_bin() :: Path.t()
  def jailer_bin, do: bin_path(:jailer)

  @doc "Ensure the firecracker release is installed for this node."
  @spec ensure_installed() :: :ok | {:error, term()}
  def ensure_installed do
    with {:ok, arch} <- Sys.Arch.current() do
      dl = Map.fetch!(@downloads, arch)

      case check_install(dl) do
        :ok -> :ok
        {:error, :not_installed} -> install(dl)
        {:error, :bad_install} -> reinstall(dl)
      end
    end
  end

  # `:ok` if `dl`'s version-specific binaries are present and executable;
  # `{:error, :not_installed}` if the install dir is empty/absent; otherwise
  # `{:error, :bad_install}` - something is there but it's the wrong version,
  # partial, or corrupt, which we cannot fix in place because `Targz` keeps
  # existing files. The remedy is to wipe and reinstall.
  @spec check_install(map()) :: :ok | {:error, :not_installed | :bad_install}
  defp check_install(dl) do
    fc = Path.join(install_dir(), dl.firecracker)
    jail = Path.join(install_dir(), dl.jailer)

    cond do
      Sys.Posix.executable?(fc) and Sys.Posix.executable?(jail) ->
        :ok

      File.dir?(install_dir()) and File.ls!(install_dir()) != [] ->
        {:error, :bad_install}

      true ->
        {:error, :not_installed}
    end
  end

  defp install(dl), do: Targz.install(dl.url, dl.sha256, install_dir())

  defp reinstall(dl) do
    _ = File.rm_rf!(install_dir())
    install(dl)
  end

  defp bin_path(key) do
    {:ok, arch} = Sys.Arch.current()
    dl = Map.fetch!(@downloads, arch)
    Path.join(install_dir(), Map.fetch!(dl, key))
  end

  defp install_dir, do: Hyper.Config.firecracker_install_dir()
end
