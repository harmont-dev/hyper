defmodule Hyper.E2e.NetworkTest do
  @moduledoc """
  Live end-to-end contract of VM egress networking on a provisioned host: a
  booted guest's `eth0` carries the uniform inner-world address
  (`172.30.0.2`), and the netns+veth+tap+NAT path it rides on actually
  reaches the internet — DNS resolves and an HTTP fetch completes.

  Self-skips (does not fail) when `[network]` is absent from `config.toml`
  (`Hyper.Cfg.Network.enabled?/0` false): a host that never provisioned
  networking has no uplink/clone_pool to test against, and this suite must
  not break integration runs on such a host. CI's `integration` job
  provisions `[network]` (see `.github/scripts/provision-kvm-host.sh`), so
  the real assertions run there.

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
    if Hyper.Cfg.Network.enabled?() do
      assert {:ok, img_id} = Hyper.Img.OciLoader.load(@image)

      # :micro, not the :base default — :base asks for 32 GiB of disk budget,
      # which the default node budget (4 GiB) refuses with :no_capacity on a
      # small CI runner.
      assert {:ok, vm} = Hyper.create_vm(%Hyper.Vm.Spec{img_id: img_id, type: :micro})
      on_exit(fn -> Hyper.Node.stop_image_vm(vm) end)

      assert {:ok, %{stdout: ip_out, exit_code: 0}} =
               await_exec(vm, ["ip", "-4", "addr", "show", "eth0"])

      assert ip_out =~ "172.30.0.2"

      assert {:ok, %{exit_code: 0}} =
               await_exec(
                 vm,
                 ["sh", "-c", "wget -qO- http://example.com >/dev/null"],
                 :timer.seconds(90)
               )
    else
      IO.puts("SKIP: [network] not enabled on this host — see Hyper.Cfg.Network.enabled?/0")
    end
  end
end
