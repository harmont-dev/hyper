defmodule Hyper.Node.TryRunContractTest do
  @moduledoc """
  `Hyper.Node.try_run/3`'s no-leak contract (#134), against this node's real
  `Hyper.Node.Budget.Hard` ledger: every VM `start_fun` boots is either
  admitted (and held against its pid) or torn down through `stop_fun` — never
  both, never neither; concurrent placements never admit past the node's hard
  headroom; and once the admitted VMs die the headroom returns exactly to
  where it started, so a refusal or an admission leaves no reservation behind.
  """
  use ExUnit.Case, async: false

  alias Hyper.Node.Budget.Hard
  alias Hyper.Vm.Instance.Spec
  alias Unit.{Bandwidth, Information}

  @moduletag :capture_log
  @moduletag :integration
  @racers 6

  test "concurrent placements never over-admit, and every refused VM is stopped" do
    before = Hard.headroom()
    spec = spec(Information.bytes(div(Information.as_bytes(before.mem), 3) + 1))
    test = self()

    stop = fn pid ->
      send(test, {:stopped, pid})
      Process.exit(pid, :kill)
      :ok
    end

    results =
      1..@racers
      |> Enum.map(fn _ ->
        Task.async(fn ->
          vm = spawn(fn -> Process.sleep(:infinity) end)
          {vm, Hyper.Node.try_run(spec, fn -> {:ok, vm} end, stop)}
        end)
      end)
      |> Task.await_many()

    stopped = drain_stopped()
    {admitted, refused} = Enum.split_with(results, &match?({_, {:ok, _}}, &1))

    assert length(admitted) in 1..2, inspect(results)
    assert Enum.map(refused, &elem(&1, 0)) |> Enum.sort() == Enum.sort(stopped)
    assert Enum.all?(admitted, fn {vm, {:ok, pid}} -> vm == pid and Process.alive?(vm) end)
    refute Enum.any?(refused, fn {vm, _} -> Process.alive?(vm) end)

    Enum.each(admitted, fn {vm, _} -> Process.exit(vm, :kill) end)
    assert eventually(fn -> Hard.headroom() == before end), "a reservation outlived its VM"
  end

  test "a VM that failed to boot is never stopped, and reserves nothing" do
    before = Hard.headroom()
    test = self()

    assert Hyper.Node.try_run(
             spec(Information.mib(1)),
             fn -> {:error, :kernel_missing} end,
             fn pid -> send(test, {:stopped, pid}) end
           ) == {:error, :kernel_missing}

    refute_received {:stopped, _}
    assert Hard.headroom() == before
  end

  defp drain_stopped(acc \\ []) do
    receive do
      {:stopped, pid} -> drain_stopped([pid | acc])
    after
      0 -> acc
    end
  end

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(20)
        eventually(fun, tries - 1)
    end
  end

  defp spec(mem) do
    %Spec{
      vcpus: 0.01,
      mem: mem,
      disk: Information.bytes(1),
      disk_bw: Bandwidth.zero(),
      net_bw: Bandwidth.zero()
    }
  end
end
