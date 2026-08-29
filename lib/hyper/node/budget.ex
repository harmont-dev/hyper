defmodule Hyper.Node.Budget do
  @moduledoc """
  Public entry point for this node's resource budget, fronting leases. Thin
  facade over `Hyper.Node.Budget.Hard`, the per-node accounting GenServer
  supervised by `Hyper.Node.Budget.Supervisor`.
  """

  alias Hyper.Node.Budget.Hard
  alias Hyper.Vm.Instance.Spec

  use OpenTelemetryDecorator

  @doc """
  Provisionally admit `spec` for `vm_id` on this node, before anything is built.

  Live soft-load check first, then an atomic hard lease. Returns a token for
  `drop/2`; the VM turns the lease into its own reservation with `claim/2`.
  """
  @spec lease(Hyper.Vm.Id.t(), Spec.t()) :: {:ok, reference()} | {:error, term()}
  @decorate with_span("Hyper.Node.Budget.lease", include: [:vm_id, :spec])
  def lease(vm_id, spec) do
    with :ok <- Hyper.Node.Budget.Soft.can_run(spec) do
      Hard.lease(vm_id, spec)
    end
  end

  @doc "Bind `vm_id`'s leased capacity to `owner` for that process's lifetime."
  @spec claim(Hyper.Vm.Id.t(), pid()) :: :ok | {:error, :no_lease}
  defdelegate claim(vm_id, owner), to: Hard

  @doc "Release the lease `token` identifies. A no-op once the VM has claimed it."
  @spec drop(Hyper.Vm.Id.t(), reference()) :: :ok
  defdelegate drop(vm_id, token), to: Hard
end
