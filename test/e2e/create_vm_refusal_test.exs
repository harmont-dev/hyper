defmodule Hyper.E2e.CreateVmRefusalTest do
  @moduledoc """
  Refusal contract of the public `Hyper.create_vm/1` on a live host:

  - a spec that NO node's budget can fit is refused with exactly
    `{:error, :no_capacity}` (the `Scheduler.place/3` contract);
  - the refusal is atomic — no device-mapper volume appears and no routing
    entry is registered;
  - both `arch` forms behave identically at refusal: `nil` (resolved to the
    host arch at create time) and the explicit host arch (pass-through),
    covering both `resolve_arch/1` branches.

  Exhaustive, not sampled: the instance-type space is 11 values, so every
  unfittable type × both arch forms is enumerated. The unfittable set is
  derived from the live budget snapshot (`NodeState.fits?/2`), which cannot
  itself be wrong-tested here — the assertions pin the public API result and
  the no-leak invariant, not the fit predicate.

  Runs only under `--only integration` on a provisioned host (see
  VmLifecycleTest for the environment contract).
  """
  use ExUnit.Case, async: false

  import Hyper.E2e

  @moduletag :integration
  @moduletag :external
  @moduletag timeout: :timer.minutes(5)

  @image System.get_env("HYPER_E2E_IMAGE", "public.ecr.aws/docker/library/alpine:3.19")

  test "every unfittable instance type is refused with :no_capacity, atomically" do
    assert {:ok, img_id} = Hyper.Img.OciLoader.load(@image)
    states = Hyper.Cluster.Budget.all_states()
    assert states != [], "no NodeState published — is the budget advertiser up?"

    unfittable =
      Enum.reject(Hyper.Vm.Instance.types(), fn type ->
        spec = Hyper.Vm.Instance.spec(type)
        Enum.any?(states, &Hyper.Node.Budget.NodeState.fits?(&1, spec))
      end)

    assert unfittable != [],
           "every instance type fits this host's budget; refusal contract unexercisable here"

    assert {:ok, host_arch} = Sys.Arch.current()
    before = snapshot()

    for type <- unfittable, arch <- [nil, host_arch] do
      spec = %Hyper.Vm.Spec{img_id: img_id, type: type, arch: arch}

      assert Hyper.create_vm(spec) == {:error, :no_capacity},
             "type #{inspect(type)} (arch #{inspect(arch)}) must refuse with :no_capacity"
    end

    assert leaks_since(before) == %{dm: MapSet.new(), routing: MapSet.new()},
           "a refused create_vm leaked cluster state"
  end
end
