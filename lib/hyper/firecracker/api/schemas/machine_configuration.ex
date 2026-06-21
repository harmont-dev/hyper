defmodule Hyper.Firecracker.Api.MachineConfiguration do
  @moduledoc """
  Provides struct and type for a MachineConfiguration
  """
  use Hyper.Firecracker.Api.Encoder

  @type t :: %__MODULE__{
          __info__: map,
          cpu_template: String.t() | nil,
          huge_pages: String.t() | nil,
          mem_size_mib: integer,
          smt: boolean | nil,
          track_dirty_pages: boolean | nil,
          vcpu_count: integer
        }

  defstruct [
    :__info__,
    :cpu_template,
    :huge_pages,
    :mem_size_mib,
    :smt,
    :track_dirty_pages,
    :vcpu_count
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      cpu_template: {:enum, ["C3", "T2", "T2S", "T2CL", "T2A", "V1N1", "None"]},
      huge_pages: {:enum, ["None", "2M"]},
      mem_size_mib: :integer,
      smt: :boolean,
      track_dirty_pages: :boolean,
      vcpu_count: :integer
    ]
  end
end
