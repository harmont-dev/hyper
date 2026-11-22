defmodule Hyper.GuestService.Conn do
  @moduledoc false

  @enforce_keys [:vm_id, :service]
  defstruct [:vm_id, :service]

  @type t :: %__MODULE__{vm_id: Hyper.Vm.Id.t(), service: Hyper.GuestService.name()}
end
