defmodule Hyper.Node.FireVMM.Provider do
  @moduledoc """
  Installs the firecracker release for the current architecture into
  `Hyper.Config.firecracker_install_dir/0` (`<work_dir>/redist/firecracker`).

  `ensure_installed/0` is idempotent: if the binaries are already present and
  executable it returns `:ok` without touching the network. Otherwise it fetches
  the official firecracker release tarball for the detected architecture via
  `Hyper.Redist.Targz` (download, SHA-256 verify, extract). The archive is
  extracted as-is — the binaries live under `release-v<ver>-<arch>/` exactly as
  firecracker ships them, and `firecracker_bin/0` / `jailer_bin/0` resolve those
  paths.

  Everything version- and architecture-specific lives in the `@downloads` table:
  the tarball URL, its pinned SHA-256, and the binary paths inside the archive.
  The SHA-256 digests are pinned here on purpose — downloading the
  `*.sha256.txt` from the same host would be trust-on-first-use and provide no
  real integrity guarantee. To bump firecracker, replace a whole `@downloads`
  entry.
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

  @doc """
  Ensure the firecracker release is installed for this node.

  Idempotent: returns `:ok` immediately if the binaries are already installed,
  otherwise fetches and installs them. Quits early with
  `{:error, {:unsupported_arch, _}}` if this machine's architecture is not
  supported.
  """
  @spec ensure_installed() :: :ok | {:error, term()}
  def ensure_installed do
    with {:ok, dl} <- download() do
      if installed?(dl), do: :ok, else: Targz.install(dl.url, dl.sha256, install_dir())
    end
  end

  # The download spec for this machine's architecture, or an error if unsupported.
  defp download do
    with {:ok, arch} <- Hyper.Sys.Arch.current() do
      case Map.fetch(@downloads, arch) do
        {:ok, dl} -> {:ok, dl}
        :error -> {:error, {:unsupported_arch, arch}}
      end
    end
  end

  # Whether `dl`'s (version-specific) binaries are installed and executable.
  defp installed?(dl) do
    Hyper.Sys.Posix.executable?(Path.join(install_dir(), dl.firecracker)) and
      Hyper.Sys.Posix.executable?(Path.join(install_dir(), dl.jailer))
  end

  defp bin_path(key) do
    Path.join(install_dir(), Map.fetch!(download!(), key))
  end

  defp download! do
    case download() do
      {:ok, dl} -> dl
      {:error, reason} -> raise ArgumentError, "no firecracker download for this host: #{inspect(reason)}"
    end
  end

  defp install_dir, do: Hyper.Config.firecracker_install_dir()
end
