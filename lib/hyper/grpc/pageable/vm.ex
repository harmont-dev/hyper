defmodule Hyper.Grpc.Pageable.Vm do
  @moduledoc false
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
