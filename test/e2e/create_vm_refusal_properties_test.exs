defmodule Hyper.E2e.CreateVmRefusalPropertiesTest do
  @moduledoc """
  Property-based refusal contract of the public `Hyper.create_vm/1`:

  - for ANY well-formed image id that was never loaded, `create_vm/1` is
    refused with exactly `{:error, :no_capacity}` — every fitting candidate
    node fails to build the rootfs for an unknown image and the scheduler
    maps all-candidates-refused to `:no_capacity` — and is never silently
    accepted;
  - the refusal is atomic: no device-mapper volume appears, no routing entry
    is registered (invariant preserved for every generated input);
  - the outcome is invariant across every instance type this host CAN fit
    (so the refusal is attributable to the image, not capacity) and across
    both `arch` forms (`nil` and the explicit host arch — both
    `resolve_arch/1` branches).

  Runs only under `--only integration` on a provisioned host (see
  VmLifecycleTest for the environment contract).
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  import Hyper.E2e

  @moduletag :integration
  @moduletag timeout: :timer.minutes(5)

  property "create_vm with an unknown image id is refused atomically" do
    states = Hyper.Cluster.Budget.all_states()
    assert states != [], "no NodeState published — is the budget advertiser up?"

    fitting =
      Enum.filter(Hyper.Vm.Instance.types(), fn type ->
        spec = Hyper.Vm.Instance.spec(type)
        Enum.any?(states, &Hyper.Node.Budget.NodeState.fits?(&1, spec))
      end)

    assert fitting != [],
           "no instance type fits this host's budget; an unknown-image refusal " <>
             "would be indistinguishable from a capacity refusal"

    assert {:ok, host_arch} = Sys.Arch.current()

    check all(
            img_id <- unknown_img_id(),
            type <- member_of(fitting),
            arch <- member_of([nil, host_arch]),
            max_runs: 25
          ) do
      before = snapshot()
      spec = %Hyper.Vm.Spec{img_id: img_id, type: type, arch: arch}

      assert Hyper.create_vm(spec) == {:error, :no_capacity}

      assert leaks_since(before) == %{dm: MapSet.new(), routing: MapSet.new()},
             "refused create_vm for unknown image #{img_id} leaked cluster state"
    end
  end

  # sha256-shaped: 64 lowercase hex chars, the form `Hyper.Img` content
  # addresses produce. The space is 2^256 — colliding with an image the E2E
  # run actually loaded is not a realistic event.
  defp unknown_img_id do
    string([?0..?9, ?a..?f], length: 64)
  end
end
