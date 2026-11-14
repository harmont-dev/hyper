defmodule Hyper.E2e.AgentExecBoundsTest do
  @moduledoc """
  Live contract of `Hyper.exec/3`'s bounds (#132) against a real guest:

  - an honest reply under the relay's 16 MiB cap arrives byte-for-byte;
  - a reply over the cap is an error that is not `:timeout`, returned well
    within the deadline instead of being buffered, and the VM stays usable:
    the next exec succeeds;
  - a command that outlives `:timeout` is `{:error, :timeout}` no later than
    the deadline plus slack, and the VM stays usable.

  Runs only under `--only integration` on a host provisioned per
  docs/cookbook/install.md.
  """
  use ExUnit.Case, async: false

  import Hyper.E2e

  alias Unit.Information

  @moduletag :integration
  @moduletag timeout: :timer.minutes(10)

  @image System.get_env("HYPER_E2E_IMAGE", "public.ecr.aws/docker/library/alpine:3.19")
  @slack_ms 2_000

  setup_all do
    {:ok, img_id} = Hyper.Img.OciLoader.load(@image)
    {:ok, vm} = Hyper.create_vm(%Hyper.Vm.Spec{img_id: img_id, type: :micro})
    on_exit(fn -> Hyper.Node.stop_image_vm(vm) end)
    {:ok, %{exit_code: 0}} = await_exec(vm, ["/bin/true"])
    %{vm: vm}
  end

  defp zeros(bytes), do: ["/bin/sh", "-c", "head -c #{bytes} /dev/zero"]

  defp assert_still_usable(vm) do
    assert {:ok, %{exit_code: 0, stdout: "alive\n"}} =
             Hyper.exec(vm, ["/bin/echo", "alive"], timeout: 10_000)
  end

  test "an honest reply under the cap arrives intact", %{vm: vm} do
    bytes = Information.as_bytes(Information.mib(8))

    assert {:ok, %{exit_code: 0, stdout: stdout}} = Hyper.exec(vm, zeros(bytes), timeout: 30_000)
    assert byte_size(stdout) == bytes
    assert stdout == :binary.copy(<<0>>, bytes)
  end

  test "a reply over the cap is a prompt non-timeout error and the VM stays usable", %{vm: vm} do
    deadline_ms = 30_000
    bytes = Information.as_bytes(Information.mib(24))

    {elapsed_us, result} =
      :timer.tc(fn -> Hyper.exec(vm, zeros(bytes), timeout: deadline_ms) end)

    assert {:error, reason} = result
    assert reason != :timeout
    assert elapsed_us < deadline_ms * 1_000
    assert_still_usable(vm)
  end

  test "a command outliving the deadline is :timeout at the deadline and the VM stays usable",
       %{vm: vm} do
    observed =
      for deadline_ms <- [700, 1_500, 4_000] do
        {elapsed_us, result} =
          :timer.tc(fn -> Hyper.exec(vm, ["/bin/sleep", "20"], timeout: deadline_ms) end)

        elapsed_ms = div(elapsed_us, 1_000)

        {deadline_ms, result, elapsed_ms >= deadline_ms - 50,
         elapsed_ms < deadline_ms + @slack_ms}
      end

    assert observed == for(d <- [700, 1_500, 4_000], do: {d, {:error, :timeout}, true, true})
    assert_still_usable(vm)
  end
end
