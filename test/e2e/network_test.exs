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

    assert {:ok, %{stdout: ip_out, exit_code: 0}} =
             await_exec(vm, ["ip", "-4", "addr", "show", "eth0"])

    assert ip_out =~ "172.30.0.2"

    # Prove real egress AND an explicit HTTP 200 — not just a non-zero-free
    # exit. `wget -S` writes the server's response headers to stderr; we merge
    # them into stdout (`2>&1`) and assert the status line is `... 200 ...`.
    # (Alpine ships busybox wget, not curl — installing curl would need egress
    # to the apk mirror first, adding a flaky dependency to prove the same
    # thing.) `-O /dev/null` discards the body; the fetch still exercises the
    # full netns → SNAT → veth → MASQUERADE → uplink path and DNS resolution.
    assert {:ok, %{stdout: http_out, exit_code: 0}} =
             await_exec(
               vm,
               ["sh", "-c", "wget -S -O /dev/null http://example.com 2>&1"],
               :timer.seconds(90)
             )

    assert http_out =~ ~r"HTTP/[\d.]+ 200\b",
           "expected an HTTP 200 status line from the guest's egress fetch, got:\n#{http_out}"
  end
end
