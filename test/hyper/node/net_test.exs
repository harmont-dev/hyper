defmodule Hyper.Node.NetTest do
  use ExUnit.Case, async: true

  alias Hyper.Node.Net
  alias Hyper.Node.Net.Ip.Host

  @host %Host{
    uplink: "if0",
    transit_prefix: {{10, 200, 0, 0}, 26},
    vm_prefix: {{0x2001, 0xDB8, 0, 0, 1, 0, 0, 0}, 80}
  }

  test "every NetId is handed out once before the pool is exhausted" do
    {claimed, pool} = claim_n(pool(), 16)

    assert Enum.sort(claimed) == Enum.to_list(0..15)
    assert claim(pool) |> elem(0) == {:error, :exhausted}
  end

  test "a released NetId is handed out again" do
    pool = pool() |> exhaust() |> release(3)

    assert claim(pool) |> elem(0) == {:ok, 3}
  end

  test "a NetId bound to an owner is handed out again once the owner dies" do
    owner = spawn(fn -> Process.sleep(:infinity) end)
    {:reply, :ok, pool} = Net.handle_call({:bind, 5, owner}, from(), exhaust(pool()))
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ref, :process, ^owner, _}
    {:noreply, pool} = Net.handle_info({:DOWN, ref, :process, owner, :killed}, pool)

    assert claim(pool) |> elem(0) == {:ok, 5}
  end

  test "a released NetId waits until every fresh one is out" do
    {{:ok, first}, pool} = claim(pool())

    assert pool |> release(first) |> claim() |> elem(0) == {:ok, first + 1}
  end

  test "released NetIds come back oldest first" do
    pool = Enum.reduce([7, 2, 11], exhaust(pool()), &release(&2, &1))
    {claimed, _} = claim_n(pool, 3)

    assert claimed == [7, 2, 11]
  end

  defp pool do
    {:ok, state} = Net.init(@host)
    state
  end

  defp claim(state) do
    {:reply, reply, state} = Net.handle_call(:claim, from(), state)
    {reply, state}
  end

  defp claim_n(state, n) do
    Enum.map_reduce(1..n, state, fn _, state ->
      {{:ok, id}, state} = claim(state)
      {id, state}
    end)
  end

  defp release(state, id) do
    {:noreply, state} = Net.handle_cast({:release, id}, state)
    state
  end

  defp exhaust(state), do: state |> claim_n(16) |> elem(1)

  defp from, do: {self(), make_ref()}
end
