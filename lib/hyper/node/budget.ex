defmodule Hyper.Node.Budget do
  @moduledoc """
  Public entry point for this node's resource budget. Thin facade over
  `Hyper.Node.Budget.Hard`, the per-node accounting GenServer supervised by
  `Hyper.Node.Budget.Supervisor`.
  """

  alias Hyper.Node.Budget.Hard

  @doc "Can this node run the given vm spec? `:ok` if yes, `{:error, reason}` otherwise."
  @spec can_run(Hyper.Vm.Instance.Spec.t()) :: :ok | {:error, term()}
  defdelegate can_run(vm_spec), to: Hard

  @doc "Reserve the spec's budget, run `callable`, and release the budget afterwards."
  @spec with_budget(Hyper.Vm.Instance.Spec.t(), (-> result)) :: result | {:error, term()}
        when result: var
  defdelegate with_budget(vm_spec, callable), to: Hard
end
