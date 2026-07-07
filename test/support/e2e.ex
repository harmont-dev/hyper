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
  `Hyper.exec/3`, retried while the guest agent is still coming up
  (`:agent_unavailable` / `:timeout` are the boot-race errors; anything else
  returns immediately).
  """
  @spec await_exec(pid() | binary(), [String.t()], non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  def await_exec(vm, argv, deadline_ms \\ :timer.seconds(60)) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_await_exec(vm, argv, deadline)
  end

  defp do_await_exec(vm, argv, deadline) do
    case Hyper.exec(vm, argv) do
      {:error, reason} when reason in [:agent_unavailable, :timeout] ->
        if System.monotonic_time(:millisecond) > deadline do
          {:error, reason}
        else
          Process.sleep(1_000)
          do_await_exec(vm, argv, deadline)
        end

      other ->
        other
    end
  end
end
