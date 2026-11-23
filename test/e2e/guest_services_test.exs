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

  @image System.get_env(
           "HYPER_E2E_PYTHON_IMAGE",
           "public.ecr.aws/docker/library/python:3.12-alpine3.19"
         )

  @client """
  import socket, sys
  s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
  s.settimeout(3)
  s.connect((2, 1100))
  s.sendall(sys.argv[1].encode() + b"\\0" + sys.argv[2].encode())
  out = b""
  try:
      while chunk := s.recv(4096):
          out += chunk
  except TimeoutError:
      pass
  sys.stdout.write(out.decode())
  """

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
    %{served: served, bare: bare}
  end

  defp boot(img_id, services) do
    {:ok, vm} =
      Hyper.create_vm(%Hyper.Vm.Spec{img_id: img_id, type: :micro, guest_services: services})

    on_exit(fn -> Hyper.Node.stop_image_vm(vm) end)
    {:ok, %{exit_code: 0}} = await_exec(vm, ["/bin/true"])
    vm
  end

  defp talk(vm, name, payload) do
    {:ok, result} = await_exec(vm, ["/usr/local/bin/python3", "-c", @client, name, payload])
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
