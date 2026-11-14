defmodule Hyper.E2e.GuestNetworkTest do
  use ExUnit.Case, async: false

  import Hyper.E2e

  @moduletag :integration
  @moduletag timeout: :timer.minutes(10)

  @image System.get_env("HYPER_E2E_IMAGE", "public.ecr.aws/docker/library/alpine:3.19")

  test "the agent configures the IPv6 address, route and resolver the host passed" do
    assert {:ok, img_id} = Hyper.Img.OciLoader.load(@image)
    assert {:ok, vm} = Hyper.create_vm(%Hyper.Vm.Spec{img_id: img_id, type: :micro})
    on_exit(fn -> Hyper.Node.stop_image_vm(vm) end)

    assert {:ok, %{stdout: cmdline, exit_code: 0}} = await_exec(vm, ["/bin/cat", "/proc/cmdline"])
    assert [_, ip6] = Regex.run(~r/\bhyper\.ip6=(\S+)/, cmdline)

    assert {:ok, %{stdout: addrs, exit_code: 0}} =
             await_exec(vm, ["/sbin/ip", "-6", "addr", "show", "dev", "eth0", "scope", "global"])

    assert addrs =~ "inet6 #{ip6}/128"

    assert {:ok, %{stdout: routes, exit_code: 0}} =
             await_exec(vm, ["/sbin/ip", "-6", "route", "show", "default"])

    assert routes =~ ~r/default via fe80::1 dev eth0/

    assert {:ok, %{stdout: resolv, exit_code: 0}} =
             await_exec(vm, ["/bin/cat", "/etc/resolv.conf"])

    assert resolv =~ ~r/^nameserver \S+$/m
  end
end
