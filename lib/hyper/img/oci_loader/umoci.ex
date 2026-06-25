defmodule Hyper.Img.OciLoader.Umoci do
  @moduledoc """
  Resolves and (when not operator-provided) installs the `umoci` binary that
  `Hyper.Img.OciLoader` uses to flatten OCI image layers.

  Two sources, in priority order (mirrors `Hyper.Node.Vmlinux`):

    1. An operator-configured path via `config :hyper, umoci_path:
       "/path/to/umoci"` (`Hyper.Config.umoci_path/0`). If set, it wins and is
       never downloaded.
    2. Otherwise the pinned static binary downloaded by `ensure_installed/0`
       into `Hyper.Config.umoci_install_dir/0` (`<work_dir>/redist/umoci`).
  """

  alias Hyper.Config
  alias Hyper.Redist

  # Pinned umoci release per architecture: the static binary's filename, its
  # download URL, and its SHA-256 (verified on download). umoci ships one raw
  # binary per arch -- https://github.com/opencontainers/umoci/releases.
  @downloads %{
    x86_64: %{
      asset: "umoci.linux.amd64",
      url: "https://github.com/opencontainers/umoci/releases/download/v0.6.0/umoci.linux.amd64",
      sha256: "b51c267ec394499e42c6fde47f240b7b7dba57ea49df0b5acd304378b82a3b71"
    },
    aarch64: %{
      asset: "umoci.linux.arm64",
      url: "https://github.com/opencontainers/umoci/releases/download/v0.6.0/umoci.linux.arm64",
      sha256: "5cfd17f2e7a4bcf9ed67ea1b955ca893d200349b9ce6a3d3707dba415f458a1f"
    }
  }

  @doc """
  Ensure a usable `umoci` is available on this node. A no-op when the operator
  configured `umoci_path` (they own it); otherwise downloads the pinned static
  binary for this node's architecture into the redist cache if it is not already
  present and executable, then marks it executable. Idempotent.
  """
  @spec ensure_installed() :: :ok | {:error, term()}
  def ensure_installed do
    if Config.umoci_path() != nil do
      :ok
    else
      with {:ok, arch} <- Sys.Arch.current() do
        path = default_path(arch)
        if Sys.Posix.executable?(path), do: :ok, else: install(arch, path)
      end
    end
  end

  @doc """
  Absolute path to the `umoci` binary: the operator-configured path if set,
  otherwise the downloaded default for this node's architecture. Raises if the
  architecture is unsupported.
  """
  @spec bin() :: Path.t()
  def bin do
    configured = Config.umoci_path()

    if configured != nil do
      configured
    else
      {:ok, arch} = Sys.Arch.current()
      default_path(arch)
    end
  end

  @spec default_path(Sys.Arch.t()) :: Path.t()
  defp default_path(arch) do
    Path.join(Config.umoci_install_dir(), Map.fetch!(@downloads, arch).asset)
  end

  @spec install(Sys.Arch.t(), Path.t()) :: :ok | {:error, term()}
  defp install(arch, path) do
    dl = Map.fetch!(@downloads, arch)

    with :ok <- Redist.File.install(dl.url, dl.sha256, path) do
      File.chmod(path, 0o755)
    end
  end
end
