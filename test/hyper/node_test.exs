defmodule Hyper.NodeTest do
  use ExUnit.Case, async: false

  test "try_run stops the VM it booted when admission itself fails, instead of leaking it" do
    if hard = Process.whereis(Hyper.Node.Budget.Hard) do
      :ok = :sys.suspend(hard)
      on_exit(fn -> :sys.resume(hard) end)
    end

    test = self()
    vm = spawn(fn -> Process.sleep(:infinity) end)

    result =
      Hyper.Node.try_run(
        Hyper.Vm.Instance.spec(:micro),
        fn -> {:ok, vm} end,
        fn pid ->
          send(test, {:stopped, pid})
          :ok
        end
      )

    assert {:error, _} = result
    assert_received {:stopped, ^vm}
  end
end
