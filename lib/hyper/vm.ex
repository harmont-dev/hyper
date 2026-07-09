defmodule Hyper.Vm do
  @moduledoc "A microVM handle (its controller pid) and cluster-wide fork operations."

  use OpenTelemetryDecorator

  @type t :: pid()

  @typedoc """
  What a VM boots from: explicit, already-jail-visible artifact paths for a cold
  boot (kernel + root drive). `boot_args` defaults to a standard serial-console
  cmdline when omitted. `vm_id` is required — networking is mandatory and
  `BootSpec.resolve/2` derives the guest NIC (`ip=` cmdline + MAC) from it.
  """
  @type source :: %{
          required(:kernel_image_path) => Path.t(),
          required(:root_drive_path) => Path.t(),
          required(:vm_id) => Hyper.Vm.Id.t(),
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
  def fast_fork(vm) when is_pid(vm) do
    case Hyper.id(vm) do
      nil ->
        {:error, :not_found}

      vm_id ->
        try do
          :erpc.call(node(vm), Hyper.Node, :fork_vm_local, [vm_id])
        catch
          :error, {:erpc, _} -> {:error, :node_unreachable}
        end
    end
  end

  @capacity_errors [
    :no_capacity,
    :exhausted,
    :cpu_saturated,
    :disk_bw_saturated,
    :net_bw_saturated,
    :mem_exhausted,
    :disk_exhausted
  ]

  @doc """
  Fork this VM, colocating on its own node when it fits (`fast_fork/1`). When
  the local node refuses admission, the parent's disk state is published as a
  new immutable delta layer and the child is scheduled cluster-wide, preferring
  nodes that already hold the image's layers. Never refuses for lack of *local*
  resources; can still error on faults (unknown VM, unreachable node, storage
  errors) or a cluster-wide `:no_capacity` or `:exhausted`.
  """
  @spec fork(t()) :: {:ok, t()} | {:error, term()}
  @decorate with_span("Hyper.Vm.fork", include: [:vm])
  def fork(vm) when is_pid(vm) do
    case fast_fork(vm) do
      {:ok, child} ->
        {:ok, child}

      {:error, reason} ->
        if capacity_error?(reason), do: slow_fork(vm), else: {:error, reason}
    end
  end

  @doc false
  # Which fast_fork refusals mean "no room on the parent's node" — the errors
  # try_run/Budget.admit emits, plus the scheduler's aggregate — as opposed to
  # faults that re-placement cannot fix.
  @spec capacity_error?(term()) :: boolean()
  def capacity_error?(reason), do: reason in @capacity_errors

  @spec slow_fork(t()) :: {:ok, t()} | {:error, term()}
  defp slow_fork(vm) do
    case Hyper.id(vm) do
      nil ->
        {:error, :not_found}

      vm_id ->
        with {:ok, %{img_id: img_id, type: type, arch: arch, boot_args: boot_args}} <-
               publish_on_owner(node(vm), vm_id) do
          Hyper.create_vm(%Hyper.Vm.Spec{
            img_id: img_id,
            type: type,
            arch: arch,
            boot_args: boot_args
          })
        end
    end
  end

  # Publication diff-copies the divergence on the owner node; no local timeout —
  # :erpc's default (infinity) is correct for a transfer proportional to writes.
  @spec publish_on_owner(node(), Hyper.Vm.Id.t()) :: {:ok, map()} | {:error, term()}
  defp publish_on_owner(node, vm_id) do
    :erpc.call(node, Hyper.Node, :publish_fork_image, [vm_id])
  catch
    :error, {:erpc, _} -> {:error, :node_unreachable}
  end
end
