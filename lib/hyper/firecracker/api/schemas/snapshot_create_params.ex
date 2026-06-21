defmodule Hyper.Firecracker.Api.SnapshotCreateParams do
  @moduledoc """
  Provides struct and type for a SnapshotCreateParams
  """
  use Hyper.Firecracker.Api.Encoder

  @type t :: %__MODULE__{
          __info__: map,
          mem_file_path: String.t(),
          snapshot_path: String.t(),
          snapshot_type: String.t() | nil
        }

  defstruct [:__info__, :mem_file_path, :snapshot_path, :snapshot_type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [mem_file_path: :string, snapshot_path: :string, snapshot_type: {:enum, ["Full", "Diff"]}]
  end
end
