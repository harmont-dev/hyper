defmodule Hyper.Firecracker.Api.Vsock do
  @moduledoc """
  Provides struct and type for a Vsock
  """
  use Hyper.Firecracker.Api.Encoder

  @type t :: %__MODULE__{
          __info__: map,
          guest_cid: integer,
          uds_path: String.t(),
          vsock_id: String.t() | nil
        }

  defstruct [:__info__, :guest_cid, :uds_path, :vsock_id]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [guest_cid: :integer, uds_path: :string, vsock_id: :string]
  end
end
