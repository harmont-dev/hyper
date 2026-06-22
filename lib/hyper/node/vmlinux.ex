defmodule Hyper.Node.Vmlinux do
  @moduledoc """
  Resolves the guest kernel (vmlinux) image for this node. Unlike
  `Hyper.Node.FireVMM.Provider` (which downloads firecracker), kernels are
  pre-provisioned by the operator; their per-architecture paths are configured
  via `config :hyper, vmlinux: %{<arch> => <path>}` (see `Hyper.Config.vmlinux/0`).

  `test_system/0` verifies the image for this node's architecture is actually
  present on disk, so a misconfigured node aborts at boot instead of failing the
  first VM launch.
  """

  @doc "Absolute path to the configured vmlinux image for `arch`."
  @spec path(Sys.Arch.t()) :: Path.t()
  def path(arch), do: Map.fetch!(Hyper.Config.vmlinux(), arch)

  @doc """
  Ensure this node's vmlinux image is configured and present. Returns
  `{:error, {:vmlinux_unconfigured, arch}}` if no path is set for the node's
  architecture, or `{:error, {:vmlinux_missing, path}}` if the configured file
  is absent.
  """
  @spec test_system() :: :ok | {:error, term()}
  def test_system do
    with {:ok, arch} <- Sys.Arch.current() do
      case Map.fetch(Hyper.Config.vmlinux(), arch) do
        {:ok, path} ->
          if File.regular?(path), do: :ok, else: {:error, {:vmlinux_missing, path}}

        :error ->
          {:error, {:vmlinux_unconfigured, arch}}
      end
    end
  end
end
