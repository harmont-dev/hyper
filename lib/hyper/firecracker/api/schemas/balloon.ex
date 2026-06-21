defmodule Hyper.Firecracker.Api.Balloon do
  @moduledoc """
  Provides struct and type for a Balloon
  """
  use Hyper.Firecracker.Api.Encoder

  @type t :: %__MODULE__{
          __info__: map,
          amount_mib: integer,
          deflate_on_oom: boolean,
          free_page_hinting: boolean | nil,
          free_page_reporting: boolean | nil,
          stats_polling_interval_s: integer | nil
        }

  defstruct [
    :__info__,
    :amount_mib,
    :deflate_on_oom,
    :free_page_hinting,
    :free_page_reporting,
    :stats_polling_interval_s
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount_mib: :integer,
      deflate_on_oom: :boolean,
      free_page_hinting: :boolean,
      free_page_reporting: :boolean,
      stats_polling_interval_s: :integer
    ]
  end
end
