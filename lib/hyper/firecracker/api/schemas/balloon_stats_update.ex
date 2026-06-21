defmodule Hyper.Firecracker.Api.BalloonStatsUpdate do
  @moduledoc """
  Provides struct and type for a BalloonStatsUpdate
  """
  use Hyper.Firecracker.Api.Encoder

  @type t :: %__MODULE__{__info__: map, stats_polling_interval_s: integer}

  defstruct [:__info__, :stats_polling_interval_s]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [stats_polling_interval_s: :integer]
  end
end
