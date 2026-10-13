defmodule Hyper.SuidHelper.Network do
  @moduledoc """
  Unimplemented placeholder pending the VM-networking rewrite.

  Mirrors the setuid helper's `network` subcommands (`prepare --vm-id --uid`,
  `teardown --vm-id --uid`, `teardown-orphan --vm-id`, `host-init`), which
  themselves return an unimplemented error without touching the system. Nothing
  in Hyper calls this module; VMs currently boot with no NIC.
  """

  @type err :: Hyper.SuidHelper.err()

  @doc false
  @spec argv(:prepare | :teardown, Hyper.Vm.Id.t(), non_neg_integer()) :: no_return()
  def argv(_op, _vm_id, _uid),
    do:
      raise("Hyper.SuidHelper.Network.argv/3 is unimplemented: VM networking is being rewritten")

  @doc false
  @spec argv(:teardown_orphan, Hyper.Vm.Id.t()) :: no_return()
  def argv(_op, _vm_id),
    do:
      raise("Hyper.SuidHelper.Network.argv/2 is unimplemented: VM networking is being rewritten")

  @doc "Unimplemented: will prepare `vm_id`'s networking once the rewrite lands."
  @spec prepare(Hyper.Vm.Id.t(), non_neg_integer()) :: {:error, :unimplemented}
  def prepare(_vm_id, _uid), do: {:error, :unimplemented}

  @doc "Unimplemented: will tear down `vm_id`'s networking once the rewrite lands."
  @spec teardown(Hyper.Vm.Id.t(), non_neg_integer()) :: {:error, :unimplemented}
  def teardown(_vm_id, _uid), do: {:error, :unimplemented}

  @doc "Unimplemented: will tear down an orphaned VM's networking by id alone."
  @spec teardown_orphan(Hyper.Vm.Id.t()) :: {:error, :unimplemented}
  def teardown_orphan(_vm_id), do: {:error, :unimplemented}

  @doc "Unimplemented: will perform host-wide networking setup."
  @spec host_init() :: {:error, :unimplemented}
  def host_init, do: {:error, :unimplemented}
end
