defmodule Hyper.Node.UsersTest do
  use ExUnit.Case, async: true

  alias Hyper.Node.Users
  alias Hyper.Node.Users.State

  @min 100
  @max 115

  test "a released uid waits until every fresh one is out" do
    {{:ok, first}, pool} = claim(pool())

    assert pool |> release(first) |> claim() |> elem(0) == {:ok, first + 1}
  end

  test "released uids come back oldest first" do
    pool = Enum.reduce([107, 102, 111], exhaust(pool()), &release(&2, &1))

    {claimed, _pool} = Enum.map_reduce(1..3, pool, fn _, pool -> claim(pool) end)

    assert claimed == [{:ok, 107}, {:ok, 102}, {:ok, 111}]
  end

  test "a uid bound to an owner is handed out again once the owner dies" do
    owner = spawn(fn -> Process.sleep(:infinity) end)
    {:reply, :ok, pool} = Users.handle_call({:bind, 105, owner}, from(), exhaust(pool()))
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ref, :process, ^owner, _}
    {:noreply, pool} = Users.handle_info({:DOWN, ref, :process, owner, :killed}, pool)

    assert claim(pool) |> elem(0) == {:ok, 105}
  end

  defp pool, do: %State{max: @max, next: @min}

  defp exhaust(pool) do
    {_claimed, pool} = Enum.map_reduce(@min..@max, pool, fn _, pool -> claim(pool) end)
    {{:error, :exhausted}, pool} = claim(pool)
    pool
  end

  defp claim(pool) do
    {:reply, reply, pool} = Users.handle_call({:new}, from(), pool)
    {reply, pool}
  end

  defp release(pool, id) do
    {:noreply, pool} = Users.handle_cast({:free, id}, pool)
    pool
  end

  defp from, do: {self(), make_ref()}
end
