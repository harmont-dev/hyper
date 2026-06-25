defmodule Hyper.Img.OciLoader.Umoci do
  @moduledoc """
  Resolves and (when not operator-provided) installs the `umoci` binary that
  `Hyper.Img.OciLoader` uses to flatten OCI image layers.

  Two sources, in priority order (mirrors `Hyper.Node.Vmlinux`):

    1. An operator-configured path via `config :hyper, umoci_path: "/path/to/umoci"`
       (`Hyper.Config.umoci_path/0`). If set, it wins and is never downloaded.
    2. Otherwise the pinned static binary downloaded by `ensure_installed/0` into
       `Hyper.Config.umoci_install_dir/0` (`<work_dir>/redist/umoci`).

  umoci ships one raw static binary per architecture
  (`umoci.linux.amd64` / `umoci.linux.arm64`); the version and per-arch SHA-256
  are pinned below and verified on download via `Hyper.Redist.File`. The download
  is a plain file (not an archive) with no execute bit, so it is `chmod`'d after
  install.
  """

  alias Hyper.Config
  alias Hyper.Redist

  @version "v0.6.0"
  @assets %{x86_64: "umoci.linux.amd64", aarch64: "umoci.linux.arm64"}
  @sha256 %{
    x86_64: "b51c267ec394499e42c6fde47f240b7b7dba57ea49df0b5acd304378b82a3b71",
    aarch64: "5cfd17f2e7a4bcf9ed67ea1b955ca893d200349b9ce6a3d3707dba415f458a1f"
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
  architecture is unsupported (boot's `test_system/0` is expected to catch that).
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

  @doc """
  Verify the resolved `umoci` is present and executable. Returns
  `{:error, {:missing_tools, ["umoci"]}}` otherwise -- the same shape
  `Hyper.Img.OciLoader.test_system/0` uses, which the gRPC layer maps to
  FAILED_PRECONDITION.
  """
  @spec test_system() :: :ok | {:error, {:missing_tools, [String.t()]}} | {:error, term()}
  def test_system do
    with {:ok, _arch} <- Sys.Arch.current() do
      if Sys.Posix.executable?(bin()),
        do: :ok,
        else: {:error, {:missing_tools, ["umoci"]}}
    end
  end

  @doc false
  @spec asset_for(Sys.Arch.t()) :: String.t()
  def asset_for(arch), do: Map.fetch!(@assets, arch)

  @doc false
  @spec asset_url(Sys.Arch.t()) :: String.t()
  def asset_url(arch) do
    "https://github.com/opencontainers/umoci/releases/download/#{@version}/#{asset_for(arch)}"
  end

  @spec default_path(Sys.Arch.t()) :: Path.t()
  defp default_path(arch), do: Path.join(Config.umoci_install_dir(), asset_for(arch))

  @spec install(Sys.Arch.t(), Path.t()) :: :ok | {:error, term()}
  defp install(arch, path) do
    with :ok <- Redist.File.install(asset_url(arch), Map.fetch!(@sha256, arch), path) do
      File.chmod(path, 0o755)
    end
  end
end
