defmodule Hyper.E2e.VmFirewallTest do
  @moduledoc """
  `Hyper.set_vm_firewall/2` against two real guests on one node.

  Laws (docs/cookbook/networking.md, Security):

    * a VM's inbound ports are closed until the operator opens them, even to
      another VM on the same host reaching it over its public IPv6 address;
    * opening a port admits new connections, and closing it again refuses them;
    * an outbound-blocked port never leaves the VM, and unblocking it restores it.
  """
  use ExUnit.Case, async: false

  import Hyper.E2e

  alias Hyper.Vm.Firewall

  @moduletag :integration
  @moduletag timeout: :timer.minutes(10)

  @image System.get_env("HYPER_E2E_IMAGE", "public.ecr.aws/docker/library/alpine:3.19")
  @port 8080

  setup_all do
    {:ok, img_id} = Hyper.Img.OciLoader.load(@image)
    vms = for _ <- 1..2, do: boot(img_id)
    on_exit(fn -> Enum.each(vms, &Hyper.Node.stop_image_vm/1) end)
    [client, server] = vms
    %{client: client, server: server, server_ip6: ip6(server)}
  end

  defp boot(img_id) do
    {:ok, vm} = Hyper.create_vm(%Hyper.Vm.Spec{img_id: img_id, type: :micro})
    {:ok, %{exit_code: 0}} = await_exec(vm, ["/bin/true"])
    vm
  end

  defp ip6(vm) do
    {:ok, %{stdout: cmdline}} = await_exec(vm, ["/bin/cat", "/proc/cmdline"])
    [_, ip6] = Regex.run(~r/\bhyper\.ip6=(\S+)/, cmdline)
    ip6
  end

  defp listen(vm) do
    {:ok, %{exit_code: 0}} =
      await_exec(vm, [
        "/bin/sh",
        "-c",
        "[ -e /run/listening ] || { touch /run/listening; " <>
          "(setsid sh -c 'while :; do nc -l -p #{@port}; sleep 0.1; done' " <>
          "</dev/null >/dev/null 2>&1 &); }"
      ])

    :ok
  end

  defp reaches?(vm, host, port) do
    {:ok, %{exit_code: code}} =
      await_exec(vm, ["/usr/bin/nc", "-z", "-w", "3", host, "#{port}"])

    code == 0
  end

  defp set!(vm, inbound, outbound_blocked) do
    {:ok, firewall} = Firewall.new(inbound, outbound_blocked)
    assert Hyper.set_vm_firewall(Hyper.id(vm), firewall) == :ok
  end

  test "an inbound port opens and closes for another VM on the host", ctx do
    listen(ctx.server)

    closed = reaches?(ctx.client, ctx.server_ip6, @port)
    set!(ctx.server, [{:tcp, @port..@port//1}], [])
    opened = reaches?(ctx.client, ctx.server_ip6, @port)
    set!(ctx.server, [], [])
    reclosed = reaches?(ctx.client, ctx.server_ip6, @port)

    assert {closed, opened, reclosed} == {false, true, false}
  end

  test "a guest reaches its own listener, so a refusal is the firewall", ctx do
    listen(ctx.server)

    assert reaches?(ctx.server, "127.0.0.1", @port)
  end

  test "an outbound-blocked port never leaves the VM until unblocked", ctx do
    before = reaches?(ctx.client, "1.1.1.1", 53)
    set!(ctx.client, [], [{:tcp, 53..53//1}])
    blocked = reaches?(ctx.client, "1.1.1.1", 53)
    set!(ctx.client, [], [])
    unblocked = reaches?(ctx.client, "1.1.1.1", 53)

    assert {before, blocked, unblocked} == {true, false, true}
  end
end
