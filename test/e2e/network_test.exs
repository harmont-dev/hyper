defmodule Hyper.E2e.NetworkTest do
  @moduledoc """
  Live end-to-end contract of VM egress networking on a provisioned host: a
  booted guest's `eth0` carries the uniform inner-world address
  (`172.30.0.2`), and the netns+veth+tap+NAT path it rides on actually
  reaches the internet — DNS resolves and an HTTP fetch completes.

  VM networking is mandatory (`Hyper.Node.FireVMM.Jailer.Checks.network_ready/0`
  refuses to start a node without `[network]`), so there is nothing to skip: a
  host that reached the point of running this suite already booted the node,
  which means networking is provisioned. CI's `integration` job provisions it
  (see `.github/scripts/provision-kvm-host.sh`).

  Runs only under `--only integration` / `--include integration` on a host
  provisioned per docs/cookbook/install.md.
  """
  use ExUnit.Case, async: false

  import Hyper.E2e

  @moduletag :integration
  @moduletag timeout: :timer.minutes(10)

  # public.ecr.aws mirrors library images without Docker Hub's per-IP pull
  # limits, which shared GHA egress IPs routinely exhaust.
  @image System.get_env("HYPER_E2E_IMAGE", "public.ecr.aws/docker/library/alpine:3.19")

  test "a booted guest can reach the internet over its NIC" do
    assert {:ok, img_id} = Hyper.Img.OciLoader.load(@image)

    # :micro, not the :base default — :base asks for 32 GiB of disk budget,
    # which the default node budget (4 GiB) refuses with :no_capacity on a
    # small CI runner.
    assert {:ok, vm} = Hyper.create_vm(%Hyper.Vm.Spec{img_id: img_id, type: :micro})
    on_exit(fn -> Hyper.Node.stop_image_vm(vm) end)

    # One exec gambles on guest-agent readiness once (not per-check), with a
    # generous deadline for a cold boot on a shared runner. Hyper.exec runs argv
    # directly with no PATH (see its @doc) — a bare name returns exit 127 — so
    # route through an absolute `/bin/sh -c` and let busybox's own default PATH
    # resolve the `ip`/`wget`/`nslookup` applets inside the guest.
    #
    # `wget -S` writes response headers to stderr; `2>&1` merges them into stdout
    # so we can assert the `... 200 ...` status line. Alpine ships busybox wget
    # (not curl); `-O /dev/null` discards the body but still drives the full
    # netns → SNAT → veth → MASQUERADE → uplink path and DNS resolution.
    script =
      "echo '--ip--'; ip addr show eth0 2>&1; " <>
        "echo '--resolv--'; cat /etc/resolv.conf 2>&1; " <>
        "echo '--route--'; ip route 2>&1; " <>
        "echo '--egress-by-ip--'; wget -T 10 -S -O /dev/null http://1.1.1.1/ 2>&1 | head -4; " <>
        "echo '--dns--'; nslookup example.com 1.1.1.1 2>&1 | head -8; " <>
        "echo '--http--'; wget -S -O /dev/null http://example.com 2>&1"

    assert {:ok, %{stdout: out, exit_code: _}} =
             await_exec(vm, ["/bin/sh", "-c", script], :timer.seconds(120))

    require Logger
    Logger.warning("=== GUEST NET DIAG ===\n#{out}\n=== END GUEST NET DIAG ===")

    assert out =~ "172.30.0.2", "guest eth0 lacks the inner-world address:\n#{out}"

    assert out =~ ~r"HTTP/[\d.]+ 200\b",
           "expected an HTTP 200 status line from the guest's egress fetch:\n#{out}"
  end
end
