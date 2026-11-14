defmodule Hyper.Node.WorkDir.PlanPropertiesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise

  alias Hyper.Node.WorkDir.Plan

  @node_uid 1000
  @group_other 0o077

  defp entry_gen do
    gen all(
          id <- integer(0..1_000_000),
          kind <- member_of([:dir, :data]),
          mode <- integer(0..0o7777),
          owner <- member_of([@node_uid, 0, 1001])
        ) do
      type = if kind == :dir, do: :directory, else: :regular
      {"/w/#{kind}-#{id}", kind, %File.Stat{type: type, mode: mode, uid: owner}}
    end
  end

  defp entries_gen, do: uniq_list_of(entry_gen(), uniq_fun: &elem(&1, 0), max_length: 12)

  defp owned_entries_gen do
    map(entries_gen(), fn entries ->
      Enum.map(entries, fn {path, kind, st} -> {path, kind, %{st | uid: @node_uid}} end)
    end)
  end

  defp apply_changes(entries, changes) do
    to = Map.new(changes, fn {path, _from, to} -> {path, to} end)

    Enum.map(entries, fn {path, kind, st} ->
      {path, kind, %{st | mode: Map.get(to, path, st.mode)}}
    end)
  end

  property "every change strips group and other bits and keeps the owner's" do
    check all(entries <- owned_entries_gen()) do
      {:ok, changes} = Plan.plan(entries, @node_uid)

      for {_path, from, to} <- changes do
        assert band(to, @group_other) == 0
        assert band(to, bnot(@group_other)) == band(from, bnot(@group_other))
      end
    end
  end

  property "exactly the node-owned entries readable by others are changed, in order" do
    check all(entries <- owned_entries_gen()) do
      {:ok, changes} = Plan.plan(entries, @node_uid)

      exposed = for {path, _, st} <- entries, band(st.mode, @group_other) != 0, do: path
      assert Enum.map(changes, &elem(&1, 0)) == exposed
    end
  end

  property "replanning after applying the changes changes nothing" do
    check all(entries <- owned_entries_gen()) do
      {:ok, changes} = Plan.plan(entries, @node_uid)
      assert Plan.plan(apply_changes(entries, changes), @node_uid) == {:ok, []}
    end
  end

  property "the first exposed entry the node does not own refuses the plan" do
    check all(entries <- entries_gen()) do
      foreign =
        Enum.find(entries, fn {_, _, st} ->
          st.uid != @node_uid and band(st.mode, @group_other) != 0
        end)

      case {foreign, Plan.plan(entries, @node_uid)} do
        {nil, result} ->
          assert {:ok, _} = result

        {{path, _, st}, result} ->
          assert result == {:error, {:not_owned, path, st.uid, band(st.mode, 0o7777)}}
      end
    end
  end

  property "a dir entry that is not a directory is refused whatever its mode or owner" do
    check all(
            entries <- owned_entries_gen(),
            type <- member_of([:regular, :symlink, :device, :other]),
            mode <- integer(0..0o7777),
            owner <- member_of([@node_uid, 0])
          ) do
      bad = {"/w/not-a-dir", :dir, %File.Stat{type: type, mode: mode, uid: owner}}
      assert Plan.plan([bad | entries], @node_uid) == {:error, {:not_a_directory, "/w/not-a-dir"}}
    end
  end
end
