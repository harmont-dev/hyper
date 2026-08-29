defmodule Hyper.Node.Budget.HardStatePropertiesTest do
  @moduledoc """
  Laws of the pure ledger core, `Hyper.Node.Budget.Hard.State`.

  The ledger holds two kinds of entry against one node's caps:

    * a **lease** — capacity granted to a boot that has not happened yet, held
      against a placing caller, carrying an expiry;
    * a **reservation** — capacity held against a live VM, created by `claim`ing
      an existing lease.

  Both occupy capacity. That is the contract the whole design rests on: a VM
  that is *about to exist* must be as visible to admission as one that already
  does, or a concurrent herd boots against headroom nothing has taken.

  The laws pinned here:

    * **Inverse** — `drop` undoes `lease` exactly; `release` then `claim`
      restores the allocation unchanged.
    * **Conservation** — `claim` moves an entry between kinds without changing
      what is allocated; allocation is always the sum of live entries, in any
      order.
    * **Refusal** — `lease` refuses exactly when the spec would cross a cap, and
      leases exhaust caps identically to reservations. `claim` of an unknown
      vm_id is refused rather than silently reserving.
    * **Never under-reserve** — no operation releases capacity out from under a
      claimed reservation: not `drop`, not a stale token, not `expire`.

  The last family is the important one. Over-reserving costs capacity and heals;
  under-reserving means a VM is running that the ledger cannot see, which is how
  the host reaches the OOM killer with headroom to spare on paper.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties
  use Unit.Operators

  alias Hyper.Node.Budget.Hard.State
  alias Hyper.Vm.Instance.Spec
  alias Unit.Bandwidth
  alias Unit.Information

  # Expiries are monotonic milliseconds, compared by `expire/2` against a `now`
  # the caller supplies — so every law here is pure, with no clock and no sleep.
  @never 1_000_000_000
  @long_ago -1

  describe "inverse laws" do
    property "dropping a lease restores the allocation it took" do
      check all({s, caps} <- spec_within_caps(), id <- vm_id()) do
        empty = State.new()
        {:ok, token, leased} = State.lease(empty, id, s, caps, @never)

        assert State.allocated(State.drop(leased, id, token)) == State.allocated(empty)
      end
    end

    property "releasing a claimed reservation and re-claiming it restores the allocation" do
      check all({s, caps} <- spec_within_caps(), id <- vm_id()) do
        {:ok, _token, leased} = State.lease(State.new(), id, s, caps, @never)
        {:ok, claimed} = State.claim(leased, id, ref())
        before = State.allocated(claimed)

        rebound =
          claimed
          |> State.release(id, @never)
          |> State.claim(id, ref())
          |> ok!()

        assert State.allocated(rebound) == before
      end
    end
  end

  describe "conservation laws" do
    property "claiming a lease does not change what is allocated" do
      check all({s, caps} <- spec_within_caps(), id <- vm_id()) do
        {:ok, _token, leased} = State.lease(State.new(), id, s, caps, @never)
        {:ok, claimed} = State.claim(leased, id, ref())

        assert State.allocated(claimed) == State.allocated(leased)
      end
    end

    property "allocation is the sum of live entries, whatever order they arrived in" do
      check all({specs, caps} <- specs_within_caps(), shuffled <- shuffled(specs)) do
        assert allocate_all(specs, caps) == allocate_all(shuffled, caps)

        total_mem = specs |> Enum.map(&Information.as_bytes(&1.mem)) |> Enum.sum()
        total_disk = specs |> Enum.map(&Information.as_bytes(&1.disk)) |> Enum.sum()

        %{mem: mem, disk: disk} = allocate_all(specs, caps)
        assert Information.as_bytes(mem) == total_mem
        assert Information.as_bytes(disk) == total_disk
      end
    end
  end

  describe "refusal contract" do
    property "a lease is refused exactly when it would cross a cap" do
      check all({held, s, caps} <- held_plus_spec()) do
        state = lease_all(held, caps)

        %{mem: mem, disk: disk} = State.allocated(state)
        fits? = mem + s.mem <= caps.mem and disk + s.disk <= caps.disk

        case State.lease(state, "vm-candidate", s, caps, @never) do
          {:ok, _token, _state} -> assert fits?
          {:error, reason} -> assert not fits? and reason in [:mem_exhausted, :disk_exhausted]
        end
      end
    end

    property "leases exhaust caps exactly as reservations do" do
      check all(%{mem: mem_mib, disk: disk_mib, count: k} <- sized_for_k()) do
        caps = %{mem: Information.mib(mem_mib * k), disk: Information.mib(disk_mib * k)}
        s = spec(mem_mib, disk_mib)

        # k leases fill the node with nothing claimed at all.
        state = lease_all(List.duplicate(s, k), caps)

        assert {:error, reason} = State.lease(state, "vm-overflow", s, caps, @never)
        assert reason in [:mem_exhausted, :disk_exhausted]
      end
    end

    property "claiming a vm_id with no lease is refused, never silently reserved" do
      check all(id <- vm_id()) do
        empty = State.new()

        assert {:error, :no_lease} = State.claim(empty, id, ref())
        assert State.allocated(empty) == State.allocated(State.new())
      end
    end
  end

  describe "never under-reserve" do
    property "dropping a claimed vm_id does not release its reservation" do
      check all({s, caps} <- spec_within_caps(), id <- vm_id()) do
        {:ok, token, leased} = State.lease(State.new(), id, s, caps, @never)
        {:ok, claimed} = State.claim(leased, id, ref())

        assert State.allocated(State.drop(claimed, id, token)) == State.allocated(claimed)
      end
    end

    property "a stale token never drops the lease that replaced it" do
      check all({s, caps} <- spec_within_caps(), id <- vm_id()) do
        {:ok, stale, leased} = State.lease(State.new(), id, s, caps, @never)
        {:ok, claimed} = State.claim(leased, id, ref())

        # The owner died and the entry went back to a grace lease with a FRESH
        # token. The placing caller's `drop`, arriving late, must not take it.
        regraced = State.release(claimed, id, @never)

        assert State.allocated(State.drop(regraced, id, stale)) == State.allocated(regraced)
      end
    end

    property "expire removes only leases past their deadline, never a reservation" do
      check all(mem_mib <- integer(1..512), disk_mib <- integer(1..512)) do
        s = spec(mem_mib, disk_mib)
        caps = %{mem: Information.mib(mem_mib * 2), disk: Information.mib(disk_mib * 2)}

        # BOTH entries carry an expired deadline; only the unclaimed one may go.
        # Claiming is what makes a deadline stop applying.
        state =
          State.new()
          |> lease!("vm-expiring", s, caps, @long_ago)
          |> lease!("vm-claimed", s, caps, @long_ago)
          |> State.claim("vm-claimed", ref())
          |> ok!()

        {expired, swept} = State.expire(state, 0)

        assert expired == ["vm-expiring"]
        assert State.allocated(swept) == State.allocated(lease_all([s], caps))
      end
    end

    property "no interleaving of operations exceeds the caps or loses an entry" do
      check all({ops, s, caps} <- op_sequence()) do
        {state, model} =
          Enum.reduce(ops, {State.new(), %{}}, fn op, acc -> apply_op(op, s, caps, acc) end)

        %{mem: mem, disk: disk} = State.allocated(state)

        assert mem <= caps.mem, "leases + reservations exceeded the memory cap"
        assert disk <= caps.disk, "leases + reservations exceeded the disk cap"

        assert Information.as_bytes(mem) == map_size(model) * Information.as_bytes(s.mem)
        assert Information.as_bytes(disk) == map_size(model) * Information.as_bytes(s.disk)
      end
    end
  end

  # The model mirrors only the BOOKKEEPING (which vm_ids hold capacity), never
  # the fit rule: it records a lease when State grants one and skips it when
  # State refuses. The cap invariant above is what actually tests the fit rule,
  # so nothing here recomputes the implementation.
  defp apply_op({:lease, id}, s, caps, {state, model}) do
    case State.lease(state, id, s, caps, @never) do
      {:ok, token, state} -> {state, Map.put(model, id, {:leased, token})}
      {:error, _} -> {state, model}
    end
  end

  defp apply_op({:claim, id}, _s, _caps, {state, model}) do
    case State.claim(state, id, ref()) do
      {:ok, state} -> {state, Map.put(model, id, :claimed)}
      {:error, :no_lease} -> {state, model}
    end
  end

  defp apply_op({:drop, id}, _s, _caps, {state, model}) do
    case Map.get(model, id) do
      {:leased, token} -> {State.drop(state, id, token), Map.delete(model, id)}
      _ -> {state, model}
    end
  end

  defp op_sequence do
    gen all(
          mem_mib <- integer(1..64),
          disk_mib <- integer(1..64),
          slots <- integer(1..6),
          ids <- uniq_list_of(vm_id(), min_length: 1, max_length: 6),
          ops <-
            list_of(
              tuple({member_of([:lease, :claim, :drop]), member_of(ids)}),
              max_length: 30
            )
        ) do
      s = spec(mem_mib, disk_mib)
      caps = %{mem: Information.mib(mem_mib * slots), disk: Information.mib(disk_mib * slots)}
      {ops, s, caps}
    end
  end

  defp spec(mem_mib, disk_mib) do
    %Spec{
      vcpus: 1,
      mem: Information.mib(mem_mib),
      disk: Information.mib(disk_mib),
      disk_bw: Bandwidth.zero(),
      net_bw: Bandwidth.zero()
    }
  end

  # Caps are built FROM the spec (spec + slack) rather than generated and
  # filtered, so a fitting pair is produced by construction every time.
  defp spec_within_caps do
    gen all(
          mem_mib <- integer(0..8192),
          disk_mib <- integer(0..8192),
          slack_mem <- integer(0..8192),
          slack_disk <- integer(0..8192)
        ) do
      {spec(mem_mib, disk_mib),
       %{
         mem: Information.mib(mem_mib + slack_mem),
         disk: Information.mib(disk_mib + slack_disk)
       }}
    end
  end

  defp specs_within_caps do
    gen all(
          pairs <- list_of(tuple({integer(0..512), integer(0..512)}), max_length: 12),
          slack <- integer(0..1024)
        ) do
      specs = Enum.map(pairs, fn {m, d} -> spec(m, d) end)
      mem = pairs |> Enum.map(&elem(&1, 0)) |> Enum.sum()
      disk = pairs |> Enum.map(&elem(&1, 1)) |> Enum.sum()

      {specs, %{mem: Information.mib(mem + slack), disk: Information.mib(disk + slack)}}
    end
  end

  # A pre-held set plus a candidate spec, with caps that may or may not fit it —
  # the boundary is what the refusal property is probing, so caps are NOT sized
  # to guarantee a fit here.
  defp held_plus_spec do
    gen all(
          held <- list_of(tuple({integer(0..256), integer(0..256)}), max_length: 8),
          cand_mem <- integer(0..512),
          cand_disk <- integer(0..512),
          cap_mem <- integer(0..2048),
          cap_disk <- integer(0..2048)
        ) do
      {Enum.map(held, fn {m, d} -> spec(m, d) end), spec(cand_mem, cand_disk),
       %{mem: Information.mib(cap_mem), disk: Information.mib(cap_disk)}}
    end
  end

  defp sized_for_k do
    gen all(mem <- integer(1..512), disk <- integer(1..512), count <- integer(1..8)) do
      %{mem: mem, disk: disk, count: count}
    end
  end

  defp shuffled(list), do: map(constant(list), &Enum.shuffle/1)

  defp vm_id, do: map(positive_integer(), &"vm-#{&1}")

  defp ref, do: make_ref()

  # Lease every spec that fits, ignoring refusals — the caller supplies caps
  # that make the outcome meaningful.
  defp lease_all(specs, caps) do
    specs
    |> Enum.with_index()
    |> Enum.reduce(State.new(), fn {s, i}, acc ->
      case State.lease(acc, "vm-held-#{i}", s, caps, @never) do
        {:ok, _token, acc} -> acc
        {:error, _} -> acc
      end
    end)
  end

  defp allocate_all(specs, caps), do: specs |> lease_all(caps) |> State.allocated()

  defp lease!(state, id, s, caps, expires_at) do
    {:ok, _token, state} = State.lease(state, id, s, caps, expires_at)
    state
  end

  defp ok!({:ok, state}), do: state
end
