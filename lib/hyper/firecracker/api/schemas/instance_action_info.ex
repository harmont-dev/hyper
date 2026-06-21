defmodule Hyper.Firecracker.Api.InstanceActionInfo do
  @moduledoc """
  Provides struct and type for a InstanceActionInfo
  """
  use Hyper.Firecracker.Api.Encoder

  @type t :: %__MODULE__{__info__: map, action_type: String.t()}

  defstruct [:__info__, :action_type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [action_type: {:enum, ["FlushMetrics", "InstanceStart", "SendCtrlAltDel"]}]
  end
end
