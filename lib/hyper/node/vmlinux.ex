defmodule Hyper.Node.Vmlinux do
  @moduledoc """
  Resolves the guest kernel (vmlinux) image for this node.

  Two sources, in priority order:

    1. An operator-configured path for the node's architecture, via
       `config :hyper, vmlinux: %{<arch> => <path>}` (see `Hyper.Config.vmlinux/0`).
       If set, it wins - the operator can pin a custom kernel.
    2. Otherwise, the default kernel downloaded by
       `Hyper.Node.FireVMM.VmLinux.Provider` (highest version for the arch).

  `test_system/0` verifies that whichever source applies actually yields a file
  on disk for this node's architecture, so a misconfigured node aborts at boot
  instead of failing the first VM launch.
  """

  alias Hyper.Node.FireVMM.VmLinux.Provider

  @doc """
  Absolute path to the kernel image for `arch`: the operator-configured path if
  set, otherwise the Provider's default kernel. Raises if neither resolves
  (boot's `test_system/0` is expected to have caught that first).
  """
  @spec path(Sys.Arch.t()) :: Path.t()
  def path(arch) do
    case Map.fetch(Hyper.Config.vmlinux(), arch) do
      {:ok, path} ->
        path

      :error ->
        {:ok, path} = Provider.default_path(arch)
        path
    end
  end

  @doc """
  Ensure this node's vmlinux image is present. With an operator-configured path,
  returns `{:error, {:vmlinux_missing, path}}` if that file is absent. Otherwise
  falls back to the Provider's default kernel and returns
  `{:error, {:vmlinux_missing, path}}` if it is absent, or `{:error, {:no_kernel, arch}}`
  if the manifest has no kernel for this architecture.
  """
  @spec test_system() :: :ok | {:error, term()}
  def test_system do
    with {:ok, arch} <- Sys.Arch.current() do
      case Map.fetch(Hyper.Config.vmlinux(), arch) do
        {:ok, path} ->
          present(path)

        :error ->
          case Provider.default_path(arch) do
            {:ok, path} -> present(path)
            {:error, _} = err -> err
          end
      end
    end
  end

  defp present(path) do
    if File.regular?(path), do: :ok, else: {:error, {:vmlinux_missing, path}}
  end
end
