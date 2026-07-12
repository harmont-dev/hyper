defmodule Hyper.Grpc.Pageable.Vm do
  @moduledoc """
  `Hyper.Grpc.Pageable` for the cluster VM listing: `{vm_id, node}` pairs from
  `Hyper.Cluster.Routing.all/0`. The cursor is the `vm_id` -- already a unique,
  totally-ordered binary -- so no extra encoding is needed.
  """
  @behaviour Hyper.Grpc.Pageable

  @impl true
  @spec cursor({Hyper.Vm.Id.t(), node()}) :: binary()
  def cursor({vm_id, _node}), do: vm_id

  @impl true
  @spec default_page_size() :: pos_integer()
  def default_page_size, do: 100

  @impl true
  @spec max_page_size() :: pos_integer()
  def max_page_size, do: 1000
end
