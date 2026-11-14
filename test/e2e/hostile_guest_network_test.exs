defmodule Hyper.E2e.HostileGuestNetworkTest do
  @moduledoc """
  A root shell inside a real guest, turned against the host it runs on.

  Laws (docs/cookbook/networking.md, Security):

    * a guest opens no connection to any address the host holds, over IPv4 or
      IPv6, on any interface;
    * a guest never reaches the provider's metadata service;
    * while it still reaches the internet, so the refusals above are the
      firewall and not a guest without a network.
  """
  use ExUnit.Case, async: false

  import Hyper.E2e

  @moduletag :integration
  @moduletag timeout: :timer.minutes(10)

  @image System.get_env("HYPER_E2E_IMAGE", "public.ecr.aws/docker/library/alpine:3.19")
  @connect_timeout_s 3

  setup_all do
    {:ok, img_id} = Hyper.Img.OciLoader.load(@image)
    {:ok, vm} = Hyper.create_vm(%Hyper.Vm.Spec{img_id: img_id, type: :micro})
    on_exit(fn -> Hyper.Node.stop_image_vm(vm) end)
    {:ok, %{exit_code: 0}} = await_exec(vm, ["/bin/true"])
    %{vm: vm}
  end

  defp host_addresses do
    {:ok, ifaddrs} = :inet.getifaddrs()

    for {_name, opts} <- ifaddrs,
        {:addr, addr} <- opts,
        not loopback?(addr),
        not link_local?(addr),
        uniq: true,
        do: addr
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_), do: false

  defp link_local?({169, 254, _, _}), do: true
  defp link_local?({a, _, _, _, _, _, _, _}), do: Bitwise.band(a, 0xFFC0) == 0xFE80
  defp link_local?(_), do: false

  defp guest_tcp(vm, addr, port) do
    {:ok, %{exit_code: code}} =
      await_exec(vm, [
        "/usr/bin/nc",
        "-z",
        "-w",
        "#{@connect_timeout_s}",
        to_string(:inet.ntoa(addr)),
        "#{port}"
      ])

    code
  end

  test "the guest opens no connection to any host address", %{vm: vm} do
    {:ok, listener} =
      :gen_tcp.listen(0, [:inet6, {:ipv6_v6only, false}, active: false, reuseaddr: true])

    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, port} = :inet.port(listener)
    addrs = host_addresses()
    assert addrs != []

    for addr <- addrs, do: guest_tcp(vm, addr, port)

    assert :gen_tcp.accept(listener, 1_000) == {:error, :timeout},
           "a guest connection reached the host on one of #{inspect(addrs)}"
  end

  test "the guest never reaches the metadata service", %{vm: vm} do
    assert guest_tcp(vm, {169, 254, 169, 254}, 80) != 0
  end

  test "the guest still reaches the internet", %{vm: vm} do
    assert guest_tcp(vm, {1, 1, 1, 1}, 53) == 0
  end
end
