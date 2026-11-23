defmodule Hyper.E2e.GuestServicesTest do
  @moduledoc """
  Guest services against real guests on one node.

  Laws:

    * a guest reaches a service attached to its VM over vsock by name, and the
      handler gets the bytes that follow the name;
    * each VM's handler is told that VM's id, never another's;
    * a name not attached to the VM is hung up on without a byte;
    * a VM with no services attached cannot connect at all.
  """
  use ExUnit.Case, async: false

  import Hyper.E2e

  @moduletag :integration
  @moduletag timeout: :timer.minutes(10)

  @image System.get_env("HYPER_E2E_IMAGE", "public.ecr.aws/docker/library/alpine:3.19")
  @port 1100

  defmodule Echo do
    @moduledoc false
    @behaviour Hyper.GuestService.Handler
    def name, do: "echo"
    def init(conn, _arg), do: {:ok, conn}
    def handle_data("whoami", conn), do: {:reply, conn.vm_id, conn}
    def handle_data(data, conn), do: {:reply, data, conn}
  end

  setup_all do
    {:ok, img_id} = Hyper.Img.OciLoader.load(@image)
    served = for _ <- 1..2, do: boot(img_id, [%Hyper.GuestService{handler: {Echo, nil}}])
    bare = boot(img_id, [])
    on_exit(fn -> Enum.each([bare | served], &Hyper.Node.stop_image_vm/1) end)
    %{served: served, bare: bare}
  end

  defp boot(img_id, services) do
    {:ok, vm} =
      Hyper.create_vm(%Hyper.Vm.Spec{img_id: img_id, type: :micro, guest_services: services})

    {:ok, %{exit_code: 0}} =
      await_exec(vm, ["/sbin/apk", "add", "--no-cache", "socat"], :timer.minutes(3))

    vm
  end

  defp talk(vm, name, payload) do
    {:ok, result} =
      await_exec(vm, [
        "/bin/sh",
        "-c",
        "printf '#{name}\\000#{payload}' | /usr/bin/socat -t 3 - VSOCK-CONNECT:2:#{@port}"
      ])

    result
  end

  test "a guest reaches an attached service by name, starting from the bytes behind it",
       %{served: [vm | _]} do
    assert %{exit_code: 0, stdout: "hello"} = talk(vm, "echo", "hello")
  end

  test "each VM's handler is told that VM's id", %{served: served} do
    for vm <- served do
      assert %{stdout: id} = talk(vm, "echo", "whoami")
      assert id == Hyper.id(vm)
    end
  end

  test "a name the VM was not given is hung up on without a byte", %{served: [vm | _]} do
    assert %{stdout: ""} = talk(vm, "nope", "hello")
  end

  test "a VM with no services attached cannot connect", %{bare: vm} do
    assert %{exit_code: code} = talk(vm, "echo", "hello")
    assert code != 0
  end
end
