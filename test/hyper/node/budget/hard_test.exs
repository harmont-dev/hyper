defmodule Hyper.Node.Budget.HardTest do
  use ExUnit.Case, async: true

  alias Hyper.Node.Budget
  alias Hyper.Node.Budget.Alpha
  alias Hyper.Node.Budget.Hard
  alias Unit.Information

  # An isolated, unnamed Hard server with a known total capacity.
  defp start_hard(total) do
    start_supervised!({Hard, total: total, name: nil})
  end

  defp total_4g_64g do
    %Alpha{mem: Information.gib(4), disk: Information.gib(64)}
  end

  test "reports its configured total" do
    pid = start_hard(total_4g_64g())
    assert Hard.total(pid) == total_4g_64g()
  end

  test "starts fully available with nothing used" do
    pid = start_hard(total_4g_64g())
    assert Hard.used(pid) == Budget.zero()
    assert Hard.avail(pid) == total_4g_64g()
  end

  test "reserve decrements avail and increments used" do
    pid = start_hard(total_4g_64g())
    need = %Alpha{mem: Information.gib(1), disk: Information.gib(16)}

    assert {:ok, ref} = Hard.reserve(pid, need)
    assert is_reference(ref)
    assert Hard.used(pid) == need
    assert Hard.avail(pid) == %Alpha{mem: Information.gib(3), disk: Information.gib(48)}
  end

  test "reserve refuses an over-commit and leaves the ledger untouched" do
    pid = start_hard(total_4g_64g())
    too_big = %Alpha{mem: Information.gib(5), disk: Information.gib(16)}

    assert Hard.reserve(pid, too_big) == {:error, :insufficient}
    assert Hard.avail(pid) == total_4g_64g()
  end

  test "release frees the reservation" do
    pid = start_hard(total_4g_64g())
    need = %Alpha{mem: Information.gib(1), disk: Information.gib(16)}

    {:ok, ref} = Hard.reserve(pid, need)
    assert Hard.release(pid, ref) == :ok
    assert Hard.avail(pid) == total_4g_64g()
    # idempotent
    assert Hard.release(pid, ref) == :ok
  end

  test "a dead owner's reservation is auto-released" do
    pid = start_hard(total_4g_64g())
    need = %Alpha{mem: Information.gib(2), disk: Information.gib(32)}
    test = self()

    owner =
      spawn(fn ->
        {:ok, _ref} = Hard.reserve(pid, need)
        send(test, :reserved)
        Process.sleep(:infinity)
      end)

    assert_receive :reserved
    assert Hard.used(pid) == need

    Process.exit(owner, :kill)

    # Wait for the :DOWN to be processed, then assert the budget is restored.
    Process.monitor(owner)
    assert_receive {:DOWN, _, :process, ^owner, _}
    # avail/1 is a call, so it serializes after the server handled the :DOWN.
    assert Hard.avail(pid) == total_4g_64g()
  end

  test "test_system passes when capacity is configured" do
    prev = Application.get_env(:hyper, Hard)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:hyper, Hard, prev),
        else: Application.delete_env(:hyper, Hard)
    end)

    Application.put_env(:hyper, Hard, mem: 1024, disk: 4096)
    assert Hard.test_system() == :ok
  end

  test "test_system fails when capacity is unconfigured" do
    prev = Application.get_env(:hyper, Hard)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:hyper, Hard, prev),
        else: Application.delete_env(:hyper, Hard)
    end)

    Application.delete_env(:hyper, Hard)
    assert Hard.test_system() == {:error, :budget_unconfigured}
  end
end
