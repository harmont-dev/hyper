defmodule Hyper.Vm.Spec do
  @moduledoc """
  A request to create a VM: which image to boot, the instance size, the guest
  architecture, and optional kernel boot args.

  `type` defaults to `:base`. `arch` defaults to `nil`, meaning "resolve to the
  scheduling node's architecture at create time" (`Hyper.create_vm/1` fills it in
  via `Sys.Arch.current/0`). `boot_args` defaults to `nil`, meaning the standard
  serial-console cmdline (`Hyper.Node.FireVMM.BootSpec`'s default).
  """

  alias Hyper.Vm.Instance

  @enforce_keys [:img_id]
  defstruct [:img_id, :arch, :boot_args, type: :base]

  @type t :: %__MODULE__{
          img_id: Hyper.Img.id(),
          type: Instance.t(),
          arch: Instance.arch() | nil,
          boot_args: String.t() | nil
        }
end
