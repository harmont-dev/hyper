defmodule Hyper.Firecracker.Api.BootSource do
  @moduledoc """
  Provides struct and type for a BootSource
  """
  use Hyper.Firecracker.Api.Encoder

  @type t :: %__MODULE__{
          __info__: map,
          boot_args: String.t() | nil,
          initrd_path: String.t() | nil,
          kernel_image_path: String.t()
        }

  defstruct [:__info__, :boot_args, :initrd_path, :kernel_image_path]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [boot_args: :string, initrd_path: :string, kernel_image_path: :string]
  end
end
