defmodule Hyper.Node.FireVMM.VmLinux.Provider do
  @moduledoc """
  Installs the guest-kernel (vmlinux) images for the current architecture into
  `Hyper.Cfg.Dirs.vmlinux_install_dir/0` (`<work_dir>/redist/vmlinux`).

  The available kernels and their SHA-256 sums come from the statically-embedded
  `Hyper.Node.FireVMM.VmLinux.Manifest`. `ensure_installed/0` installs *every*
  build for this node's architecture and is idempotent: if all the expected
  images are already present it returns `:ok` without touching the network.
  Otherwise it fetches each missing image via `Redist.File` (download,
  SHA-256 verify, install).

  This is the download-side counterpart to operator-provided kernels; see
  `Hyper.Node.Vmlinux`, which prefers an operator-configured path and falls back
  to `default_path/1` here.
  """

  alias Hyper.Node.FireVMM.VmLinux.Manifest

  @doc "Ensure every kernel for this node's architecture is installed."
  @spec ensure_installed() :: :ok | {:error, term()}
  def ensure_installed do
    with {:ok, arch} <- Sys.Arch.current() do
      builds = Manifest.builds_for(arch)

      case install_state(install_dir(), builds) do
        :ok -> :ok
        {:error, :not_installed} -> install_all(builds)
        {:error, :bad_install} -> reinstall(builds)
      end
    end
  end

  @doc "Absolute path to the installed kernel for build `name` (e.g. \"x86_64-6.1\"). The returned path is only guaranteed to exist for the node's current architecture (the one `ensure_installed/0` installs)."
  @spec path(String.t()) :: {:ok, Path.t()} | {:error, {:unknown_build, String.t()}}
  def path(name) do
    case Manifest.fetch(name) do
      {:ok, build} -> {:ok, build_path(install_dir(), build)}
      :error -> {:error, {:unknown_build, name}}
    end
  end

  @doc "Absolute path to the default (highest-version) kernel for `arch`. The returned path is only guaranteed to exist for the node's current architecture (the one `ensure_installed/0` installs)."
  @spec default_path(Sys.Arch.t()) :: {:ok, Path.t()} | {:error, {:no_kernel, Sys.Arch.t()}}
  def default_path(arch) do
    case Manifest.default_for(arch) do
      nil -> {:error, {:no_kernel, arch}}
      build -> {:ok, build_path(install_dir(), build)}
    end
  end

  @doc """
  Install state of `builds` under `dir`: `:ok` if every asset file is present;
  `{:error, :not_installed}` if none are; `{:error, :bad_install}` if only some
  are (a partial/corrupt install - `Redist.File` keeps existing files, so
  the remedy is to wipe and reinstall).
  """
  @spec install_state(Path.t(), [Manifest.Build.t()]) ::
          :ok | {:error, :not_installed | :bad_install}
  def install_state(dir, builds) do
    present = Enum.count(builds, &File.regular?(build_path(dir, &1)))

    cond do
      present == length(builds) -> :ok
      present == 0 -> {:error, :not_installed}
      true -> {:error, :bad_install}
    end
  end

  defp install_all(builds) do
    Enum.reduce_while(builds, :ok, fn build, :ok ->
      case Redist.File.install(
             Manifest.asset_url(build),
             build.sha256,
             build_path(install_dir(), build)
           ) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # Safe to wipe wholesale: install_dir/0 is Hyper's own redist cache
  # (<work_dir>/redist/vmlinux), never operator data.
  defp reinstall(builds) do
    _ = File.rm_rf!(install_dir())
    install_all(builds)
  end

  defp build_path(dir, build), do: Path.join(dir, build.asset)

  defp install_dir, do: Hyper.Cfg.Dirs.vmlinux_install_dir()
end
