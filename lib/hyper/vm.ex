defmodule Hyper.Vm do
  @moduledoc "A microVM handle (its controller pid) and cluster-wide fork operations."

  use OpenTelemetryDecorator

  # Aspirational @specs for as-yet unimplemented stubs: `fast_fork/1` only returns
  # `{:error, :not_implemented}` and `fork/1` raises, so their success typings are
  # narrower than the public contracts. Suppress until they are built out.
  # TODO: implement fast_fork/1 and fork/1 and drop this @dialyzer suppression.
  @dialyzer {:nowarn_function, [fast_fork: 1, fork: 1]}

  @type t :: pid()

  @typedoc """
  What a VM boots from: explicit, already-jail-visible artifact paths for a cold
  boot (kernel + root drive). `boot_args` defaults to a standard serial-console
  cmdline when omitted.
  """
  @type source :: %{
          required(:kernel_image_path) => Path.t(),
          required(:root_drive_path) => Path.t(),
          optional(:boot_args) => String.t()
        }

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
  @decorate with_span("Hyper.Vm.fast_fork")
  def fast_fork(_vm) do
    {:error, :not_implemented}
  end

  @doc """
  Fork this VM. This function will never fail due to a lack of resoures. If the `Hyper.Node`
  running the given `vm` does not have sufficient resources, then this fork will create a
  snapshot, transfer it over the wire, and find an appropriate `Hyper.Node` to execute it on.
  """
  @spec fork(t()) :: t()
  @decorate with_span("Hyper.Vm.fork", include: [:vm])
  def fork(vm) do
    raise "Hyper.Vm.fork/1 is not yet implemented for #{inspect(vm)}"
  end
end
