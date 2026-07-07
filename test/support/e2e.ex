defmodule Hyper.E2e do
  @moduledoc """
  Helpers for the `:integration` E2E suite, which runs against a fully
  provisioned single-node Firecracker host (KVM, device-mapper, setuid
  helper, Postgres) — in CI, the `integration` job of ci.yml provisions the
  runner via .github/scripts/provision-kvm-host.sh.

  Requires passwordless sudo: `dm_devices/0` shells out to `sudo dmsetup ls`
  to observe kernel state Hyper itself owns via the setuid helper.
  """

  @doc "Names of all live device-mapper devices, via `sudo dmsetup ls`."
  @spec dm_devices() :: MapSet.t(String.t())
  def dm_devices do
    {out, 0} = System.cmd("sudo", ["dmsetup", "ls"], stderr_to_stdout: true)

    out
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "No devices found"))
    |> Enum.map(fn line -> line |> String.split() |> hd() end)
    |> MapSet.new()
  end

  @typedoc "Cluster-visible VM side-effect surface: dm devices + routing entries."
  @type snapshot :: %{dm: MapSet.t(String.t()), routing: MapSet.t(Hyper.Vm.Id.t())}

  @doc """
  Snapshot of every observable side effect a VM creation leaves behind:
  live device-mapper devices and registered routing entries. Take one before
  an operation that must be refused; `leaks_since/1` then reports anything
  the refusal leaked.
  """
  @spec snapshot() :: snapshot()
  def snapshot do
    %{
      dm: dm_devices(),
      routing: MapSet.new(Hyper.Cluster.Routing.all(), fn {vm_id, _node} -> vm_id end)
    }
  end

  @doc """
  Entries present now but absent from `before` — the leaks. Set difference,
  not equality: concurrent reaping/deregistration may shrink either set
  between snapshots, and shrinkage is not a leak.
  """
  @spec leaks_since(snapshot()) :: snapshot()
  def leaks_since(before) do
    now = snapshot()

    %{
      dm: MapSet.difference(now.dm, before.dm),
      routing: MapSet.difference(now.routing, before.routing)
    }
  end

  @doc "Polls `fun` every 500 ms until it returns truthy or `deadline_ms` elapses."
  @spec poll_until((-> boolean()), non_neg_integer()) :: boolean()
  def poll_until(fun, deadline_ms) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_poll(fun, deadline)
  end

  defp do_poll(fun, deadline) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) > deadline -> false
      true -> Process.sleep(500) && do_poll(fun, deadline)
    end
  end

  @doc """
  `Hyper.exec/3`, retried while the guest agent is still coming up.

  Boot-race errors that get retried: `:agent_unavailable`, `:timeout`, and
  `GRPC.RPCError` — the relay's vsock stream can connect and drop while the
  in-guest agent is still starting, which surfaces as a gRPC stream error
  rather than `:agent_unavailable`. Anything else returns immediately.
  """
  @spec await_exec(pid() | binary(), [String.t()], non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  def await_exec(vm, argv, deadline_ms \\ :timer.seconds(60)) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_await_exec(vm, argv, deadline)
  end

  defp do_await_exec(vm, argv, deadline) do
    case Hyper.exec(vm, argv) do
      {:error, reason} = err when reason in [:agent_unavailable, :timeout] ->
        retry_or_return(err, vm, argv, deadline)

      {:error, %GRPC.RPCError{}} = err ->
        retry_or_return(err, vm, argv, deadline)

      other ->
        other
    end
  end

  defp retry_or_return(err, vm, argv, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      err
    else
      Process.sleep(1_000)
      do_await_exec(vm, argv, deadline)
    end
  end
end
