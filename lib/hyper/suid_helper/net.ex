defmodule Hyper.SuidHelper.Net do
  @moduledoc "`suidhelper net` subcommands: a VM's network namespace."

  @type err :: Hyper.SuidHelper.err()

  @doc "Create `vm_id`'s netns, returning its name (`net prepare`). Idempotent."
  @spec prepare(Hyper.Vm.Id.t()) :: {:ok, String.t()} | {:error, err()}
  def prepare(_vm_id),
    do: raise("Hyper.SuidHelper.Net.prepare/1 is unimplemented: VM networking is being rewritten")

  @doc "Delete `vm_id`'s netns (`net teardown`). Idempotent."
  @spec teardown(Hyper.Vm.Id.t()) :: :ok | {:error, err()}
  def teardown(_vm_id),
    do:
      raise("Hyper.SuidHelper.Net.teardown/1 is unimplemented: VM networking is being rewritten")
end
