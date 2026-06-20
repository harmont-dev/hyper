defmodule Hyper.Node.BudgetTest do
  use ExUnit.Case, async: true

  alias Hyper.Node.Budget
  alias Hyper.Node.Budget.Alpha
  alias Hyper.Node.Budget.Hard
  alias Hyper.Vm.Instance
  alias Unit.Information

  test "alpha/1 pulls mem and disk out of a spec" do
    spec = Instance.spec(:base)
    assert Budget.alpha(spec) == %Alpha{mem: spec.mem, disk: spec.disk}
  end

  test "zero is the additive identity for Alpha" do
    a = %Alpha{mem: Information.mib(128), disk: Information.gib(2)}
    assert Budget.add(Budget.zero(), a) == a
  end

  test "add and sub act dimension-wise" do
    a = %Alpha{mem: Information.mib(100), disk: Information.gib(10)}
    b = %Alpha{mem: Information.mib(30), disk: Information.gib(4)}

    assert Budget.add(a, b) == %Alpha{mem: Information.mib(130), disk: Information.gib(14)}
    assert Budget.sub(a, b) == %Alpha{mem: Information.mib(70), disk: Information.gib(6)}
    # sub clamps per dimension: subtracting more than is present yields zero.
    assert Budget.sub(b, a) == Budget.zero()
  end

  test "fits? requires every dimension to have at least the requirement" do
    avail = %Alpha{mem: Information.mib(512), disk: Information.gib(8)}

    assert Budget.fits?(avail, %Alpha{mem: Information.mib(512), disk: Information.gib(8)})
    assert Budget.fits?(avail, %Alpha{mem: Information.mib(256), disk: Information.gib(4)})
    refute Budget.fits?(avail, %Alpha{mem: Information.mib(513), disk: Information.gib(8)})
    refute Budget.fits?(avail, %Alpha{mem: Information.mib(256), disk: Information.gib(9)})
  end

  test "havail includes this node when its hard budget fits the spec" do
    total = %Alpha{mem: Information.gib(8), disk: Information.gib(128)}
    name = :"hard_havail_fit_#{System.unique_integer([:positive])}"
    start_supervised!({Hard, total: total, name: name})

    nodes = Budget.havail(Instance.spec(:micro), nodes: [node()], server: name)
    assert nodes == [node()]
  end

  test "havail excludes this node when the spec does not fit" do
    total = %Alpha{mem: Information.mib(64), disk: Information.gib(1)}
    name = :"hard_havail_nofit_#{System.unique_integer([:positive])}"
    start_supervised!({Hard, total: total, name: name})

    # :base needs 2 GiB mem / 32 GiB disk - far over this tiny node.
    nodes = Budget.havail(Instance.spec(:base), nodes: [node()], server: name)
    assert nodes == []
  end
end
