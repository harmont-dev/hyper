defmodule Hyper.Node.IdPoolPropertiesTest do
  @moduledoc """
  Laws for the two per-VM id pools, `Hyper.Node.Users` (uid/gid) and
  `Hyper.Node.Net` (network slot), which share one bump-pointer + FIFO
  free-queue design (#134). Each id is a VM identity: handing a held id to a
  second VM is a uid / netns collision between two guests.

  Over any interleaving of claims, explicit releases, owner binds and owner
  deaths by well-behaved callers (each held id returned exactly once):

    * no id is ever handed out while it is still held;
    * every id handed out lies in the configured range;
    * a claim is refused (`:exhausted`) exactly when every id in the range is
      held — a returned id is always reusable, so nothing leaks;
    * a returned id is not reissued while a never-issued id remains.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Hyper.Node.{Net, Users}

  @pools [users: {Users, {:new}, :free}, net: {Net, :claim, :release}]

  defp op do
    one_of([
      constant(:claim),
      tuple({constant(:release), integer(0..1_000)}),
      tuple({constant(:bind_and_die), integer(0..1_000)})
    ])
  end

  for {name, {mod, claim_msg, release_msg}} <- @pools do
    property "#{name}: never reissues a held id, never leaks one, stays in range" do
      mod = unquote(mod)
      claim_msg = unquote(Macro.escape(claim_msg))
      release_tag = unquote(release_msg)

      check all(
              min <- integer(0..60_000),
              span <- integer(0..12),
              ops <- list_of(op(), max_length: 80)
            ) do
        max = min + span
        pool = new_pool(mod, min, max)

        Enum.reduce(ops, {pool, [], MapSet.new()}, fn
          :claim, {pool, held, ever} ->
            {:reply, reply, pool} = mod.handle_call(claim_msg, {self(), make_ref()}, pool)

            case reply do
              {:ok, id} ->
                refute id in held, "#{inspect(mod)} reissued held id #{id}"
                assert id in min..max
                fresh_left? = MapSet.size(ever) < span + 1

                if fresh_left?,
                  do: refute(MapSet.member?(ever, id), "reused #{id} while fresh ids remained")

                {pool, held ++ [id], MapSet.put(ever, id)}

              {:error, :exhausted} ->
                assert length(held) == span + 1, "refused with only #{length(held)} held"
                {pool, held, ever}
            end

          {:release, _}, {pool, [], ever} ->
            {pool, [], ever}

          {:release, pick}, {pool, held, ever} ->
            id = Enum.at(held, rem(pick, length(held)))
            {:noreply, pool} = mod.handle_cast({release_tag, id}, pool)
            {pool, List.delete(held, id), ever}

          {:bind_and_die, _}, {pool, [], ever} ->
            {pool, [], ever}

          {:bind_and_die, pick}, {pool, held, ever} ->
            id = Enum.at(held, rem(pick, length(held)))
            owner = spawn(fn -> :ok end)
            {:reply, :ok, pool} = mod.handle_call({:bind, id, owner}, {self(), make_ref()}, pool)
            ref = pool.owners |> Enum.find(fn {_ref, bound} -> bound == id end) |> elem(0)
            {:noreply, pool} = mod.handle_info({:DOWN, ref, :process, owner, :normal}, pool)
            {pool, List.delete(held, id), ever}
        end)
      end
    end
  end

  defp new_pool(Users, min, max), do: %Users.State{max: max, next: min}

  defp new_pool(Net, min, max),
    do: %Net.State{host: :unused_by_the_id_pool, max: max, next: min}
end
