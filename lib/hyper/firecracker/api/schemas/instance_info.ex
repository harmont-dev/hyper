defmodule Hyper.Firecracker.Api.InstanceInfo do
  @moduledoc """
  Provides struct and type for a InstanceInfo
  """
  use Hyper.Firecracker.Api.Encoder

  @type t :: %__MODULE__{
          __info__: map,
          app_name: String.t(),
          id: String.t(),
          state: String.t(),
          vmm_version: String.t()
        }

  defstruct [:__info__, :app_name, :id, :state, :vmm_version]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      app_name: :string,
      id: :string,
      state: {:enum, ["Not started", "Running", "Paused"]},
      vmm_version: :string
    ]
  end
end
