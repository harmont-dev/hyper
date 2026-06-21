defmodule Hyper.Firecracker.Api.SnapshotLoadParams do
  @moduledoc """
  Provides struct and type for a SnapshotLoadParams
  """
  use Hyper.Firecracker.Api.Encoder

  @type t :: %__MODULE__{
          __info__: map,
          clock_realtime: boolean | nil,
          enable_diff_snapshots: boolean | nil,
          mem_backend: Hyper.Firecracker.Api.MemoryBackend.t() | nil,
          mem_file_path: String.t() | nil,
          network_overrides: [Hyper.Firecracker.Api.NetworkOverride.t()] | nil,
          resume_vm: boolean | nil,
          snapshot_path: String.t(),
          track_dirty_pages: boolean | nil,
          vsock_override: Hyper.Firecracker.Api.VsockOverride.t() | nil
        }

  defstruct [
    :__info__,
    :clock_realtime,
    :enable_diff_snapshots,
    :mem_backend,
    :mem_file_path,
    :network_overrides,
    :resume_vm,
    :snapshot_path,
    :track_dirty_pages,
    :vsock_override
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      clock_realtime: :boolean,
      enable_diff_snapshots: :boolean,
      mem_backend: {Hyper.Firecracker.Api.MemoryBackend, :t},
      mem_file_path: :string,
      network_overrides: [{Hyper.Firecracker.Api.NetworkOverride, :t}],
      resume_vm: :boolean,
      snapshot_path: :string,
      track_dirty_pages: :boolean,
      vsock_override: {Hyper.Firecracker.Api.VsockOverride, :t}
    ]
  end
end
