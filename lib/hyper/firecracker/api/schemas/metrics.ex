defmodule Hyper.Firecracker.Api.Metrics do
  @moduledoc """
  Provides struct and type for a Metrics
  """
  use Hyper.Firecracker.Api.Encoder

  @type t :: %__MODULE__{__info__: map, metrics_path: String.t()}

  defstruct [:__info__, :metrics_path]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [metrics_path: :string]
  end
end
