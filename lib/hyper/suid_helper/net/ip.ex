defmodule Hyper.SuidHelper.Net.Ip do
  @moduledoc "`suidhelper net ip` subcommands: the IP link inside a VM's netns."

  alias Hyper.Node.Net.Ip.{Host, Lease}

  @type err :: Hyper.SuidHelper.err()

  @doc "Apply host-wide IP networking (`net ip host-init`). Idempotent."
  @spec host_init() :: {:ok, Host.t()} | {:error, err()}
  def host_init,
    do:
      raise(
        "Hyper.SuidHelper.Net.Ip.host_init/0 is unimplemented: VM networking is being rewritten"
      )

  @doc "Create `vm_id`'s IP link in its netns (`net ip prepare`). Idempotent."
  @spec prepare(Hyper.Vm.Id.t(), Hyper.Node.Users.id()) :: {:ok, Lease.t()} | {:error, err()}
  def prepare(_vm_id, _uid),
    do:
      raise(
        "Hyper.SuidHelper.Net.Ip.prepare/2 is unimplemented: VM networking is being rewritten"
      )

  @doc "Remove `vm_id`'s IP link by id alone (`net ip teardown`). Idempotent."
  @spec teardown(Hyper.Vm.Id.t()) :: :ok | {:error, err()}
  def teardown(_vm_id),
    do:
      raise(
        "Hyper.SuidHelper.Net.Ip.teardown/1 is unimplemented: VM networking is being rewritten"
      )
end
