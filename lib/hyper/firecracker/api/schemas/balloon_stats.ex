defmodule Hyper.Firecracker.Api.BalloonStats do
  @moduledoc """
  Provides struct and type for a BalloonStats
  """
  use Hyper.Firecracker.Api.Encoder

  @type t :: %__MODULE__{
          __info__: map,
          actual_mib: integer,
          actual_pages: integer,
          alloc_stall: integer | nil,
          async_reclaim: integer | nil,
          async_scan: integer | nil,
          available_memory: integer | nil,
          direct_reclaim: integer | nil,
          direct_scan: integer | nil,
          disk_caches: integer | nil,
          free_memory: integer | nil,
          hugetlb_allocations: integer | nil,
          hugetlb_failures: integer | nil,
          major_faults: integer | nil,
          minor_faults: integer | nil,
          oom_kill: integer | nil,
          swap_in: integer | nil,
          swap_out: integer | nil,
          target_mib: integer,
          target_pages: integer,
          total_memory: integer | nil
        }

  defstruct [
    :__info__,
    :actual_mib,
    :actual_pages,
    :alloc_stall,
    :async_reclaim,
    :async_scan,
    :available_memory,
    :direct_reclaim,
    :direct_scan,
    :disk_caches,
    :free_memory,
    :hugetlb_allocations,
    :hugetlb_failures,
    :major_faults,
    :minor_faults,
    :oom_kill,
    :swap_in,
    :swap_out,
    :target_mib,
    :target_pages,
    :total_memory
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      actual_mib: :integer,
      actual_pages: :integer,
      alloc_stall: {:integer, "int64"},
      async_reclaim: {:integer, "int64"},
      async_scan: {:integer, "int64"},
      available_memory: {:integer, "int64"},
      direct_reclaim: {:integer, "int64"},
      direct_scan: {:integer, "int64"},
      disk_caches: {:integer, "int64"},
      free_memory: {:integer, "int64"},
      hugetlb_allocations: {:integer, "int64"},
      hugetlb_failures: {:integer, "int64"},
      major_faults: {:integer, "int64"},
      minor_faults: {:integer, "int64"},
      oom_kill: {:integer, "int64"},
      swap_in: {:integer, "int64"},
      swap_out: {:integer, "int64"},
      target_mib: :integer,
      target_pages: :integer,
      total_memory: {:integer, "int64"}
    ]
  end
end
