defmodule Hyper.Vm do
  use OpenTelemetryDecorator

  @type t :: pid()

  @doc """
  Attempt to create a fast fork of this VM.

  A fast fork is guaranteed to co-locate on the same `Hyper.Node`. If the node does not have
  sufficient runtime resources (out-of-memory, out-of-cpu), then this function will gracefully
  error.

  If you want to, instead, have logic which falls back to a slow fork, ie. one which snapshots
  the state of the VM, transferring it to another node, and then spawning the VM there, then you
  should see `Hyper.Vm.fork/1`.

  """
  @spec fast_fork(t()) :: {:ok, t()} | {:error, term()}
  @decorate with_span("Hyper.Vm.fast_fork", include: [:vm])
  def fast_fork(vm) do
  end

  @doc """
  Fork this VM. This function will never fail due to a lack of resoures. If the `Hyper.Node`
  running the given `vm` does not have sufficient resources, then this fork will create a
  snapshot, transfer it over the wire, and find an appropriate `Hyper.Node` to execute it on.
  """
  @spec fork(t()) :: t()
  @decorate with_span("Hyper.Vm.fork", include: [:vm])
  def fork(vm) do
  end
end
