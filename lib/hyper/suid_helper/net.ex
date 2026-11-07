defmodule Hyper.SuidHelper.Net do
  @moduledoc "Setuid helper `net_*` requests: a VM's network namespace."

  @type err :: Hyper.SuidHelper.err()

  @doc "Create `vm_id`'s netns, returning its name (`net_prepare`). Idempotent."
  @spec prepare(Hyper.Vm.Id.t()) :: no_return()
  def prepare(_vm_id),
    do: raise("Hyper.SuidHelper.Net.prepare/1 is unimplemented: VM networking is being rewritten")

  @doc "Delete `vm_id`'s netns (`net_teardown`). Idempotent."
  @spec teardown(Hyper.Vm.Id.t()) :: no_return()
  def teardown(_vm_id),
    do:
      raise("Hyper.SuidHelper.Net.teardown/1 is unimplemented: VM networking is being rewritten")
end
