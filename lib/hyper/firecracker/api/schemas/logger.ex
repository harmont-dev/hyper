defmodule Hyper.Firecracker.Api.Logger do
  @moduledoc """
  Provides struct and type for a Logger
  """
  use Hyper.Firecracker.Api.Encoder

  @type t :: %__MODULE__{
          __info__: map,
          level: String.t() | nil,
          log_path: String.t() | nil,
          module: String.t() | nil,
          show_level: boolean | nil,
          show_log_origin: boolean | nil
        }

  defstruct [:__info__, :level, :log_path, :module, :show_level, :show_log_origin]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      level: {:enum, ["Error", "Warning", "Info", "Debug", "Trace"]},
      log_path: :string,
      module: :string,
      show_level: :boolean,
      show_log_origin: :boolean
    ]
  end
end
