defmodule Hyper.NodeTest do
  use ExUnit.Case, async: false

  test "try_run stops the VM it booted when admission itself fails, instead of leaking it" do
    refute Process.whereis(Hyper.Node.Budget.Hard)
    test = self()
    vm = spawn(fn -> Process.sleep(:infinity) end)

    result =
      Hyper.Node.try_run(
        %Hyper.Vm.Spec{img_id: "img", type: :micro},
        fn -> {:ok, vm} end,
        fn pid ->
          send(test, {:stopped, pid})
          :ok
        end
      )

    assert {:error, {:admission_failed, _}} = result
    assert_received {:stopped, ^vm}
  end
end
