defmodule Hyper.Node.Budget do
  @moduledoc """
  Public entry point for this node's resource budget. Thin facade over
  `Hyper.Node.Budget.Hard`, the per-node accounting GenServer supervised by
  `Hyper.Node.Budget.Supervisor`.
  """

  alias Hyper.Node.Budget.Hard
  alias Hyper.Vm.Instance.Spec

  use OpenTelemetryDecorator

  @doc "Can this node run the given vm spec? `:ok` if yes, `{:error, reason}` otherwise."
  @spec can_run(Hyper.Vm.Instance.Spec.t()) :: :ok | {:error, term()}
  defdelegate can_run(vm_spec), to: Hard

  @doc "Reserve the spec's budget, run `callable`, and release the budget afterwards."
  @spec with_budget(Hyper.Vm.Instance.Spec.t(), (-> result)) :: result | {:error, term()}
        when result: var
  defdelegate with_budget(vm_spec, callable), to: Hard

  @doc """
  Authoritatively confirm this node can run `spec`, reserving its budget for the
  lifetime of `owner`. Live soft-load check first, then an atomic hard reserve.
  """
  @spec admit(Spec.t(), pid()) :: :ok | {:error, term()}
  @decorate with_span("Hyper.Node.Budget.admit", include: [:spec])
  def admit(spec, owner) do
    with :ok <- Hyper.Node.Budget.Soft.can_run(spec) do
      Hard.reserve(spec, owner)
    end
  end
end
