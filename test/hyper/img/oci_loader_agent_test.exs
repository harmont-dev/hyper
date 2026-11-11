defmodule Hyper.Img.OciLoaderAgentTest do
  use ExUnit.Case, async: true

  alias Hyper.Img.OciLoader

  @agent "#!/bin/true\nagent\n"
  @outside_content "host secret\n"

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    rootfs = Path.join(tmp, "rootfs")
    host = Path.join(tmp, "host")
    File.mkdir_p!(rootfs)
    File.mkdir_p!(host)

    agent = Path.join(tmp, "agent-bin")
    File.write!(agent, @agent)

    existing = Path.join(host, "existing")
    File.write!(existing, @outside_content)
    File.chmod!(existing, 0o600)

    %{rootfs: rootfs, agent: agent, existing: existing, absent: Path.join(host, "absent")}
  end

  for {name, planted} <- [
        {"absent", :none},
        {"symlink to an existing host file", :symlink_existing},
        {"dangling symlink to a host path", :symlink_absent},
        {"regular file", :regular}
      ] do
    test "stages a fresh 0755 agent over a /hyper-init that is #{name}", ctx do
      dest = Path.join(ctx.rootfs, "hyper-init")
      plant(unquote(planted), dest, ctx)

      assert :ok = OciLoader.stage_agent_from(ctx.rootfs, ctx.agent)
      assert {:ok, %File.Stat{type: :regular, mode: mode}} = File.lstat(dest)
      assert Bitwise.band(mode, 0o7777) == 0o755
      assert File.read!(dest) == @agent
      assert_host_untouched(ctx)
    end
  end

  test "refuses an image whose /hyper-init is a directory", ctx do
    dest = Path.join(ctx.rootfs, "hyper-init")
    plant(:directory, dest, ctx)

    assert {:error, {:bad_image, :hyper_init_is_a_directory}} =
             OciLoader.stage_agent_from(ctx.rootfs, ctx.agent)

    assert File.dir?(dest)
    assert_host_untouched(ctx)
  end

  test "a missing agent binary fails the stage instead of shipping a rootfs without init", ctx do
    missing = Path.join(ctx.rootfs, "no-such-agent")

    assert {:error, :enoent} = OciLoader.stage_agent_from(ctx.rootfs, missing)
    refute File.exists?(Path.join(ctx.rootfs, "hyper-init"))
  end

  defp assert_host_untouched(ctx) do
    assert File.read!(ctx.existing) == @outside_content
    assert Bitwise.band(File.stat!(ctx.existing).mode, 0o7777) == 0o600
    refute File.exists?(ctx.absent)
  end

  defp plant(:none, _dest, _ctx), do: :ok
  defp plant(:symlink_existing, dest, ctx), do: File.ln_s!(ctx.existing, dest)
  defp plant(:symlink_absent, dest, ctx), do: File.ln_s!(ctx.absent, dest)
  defp plant(:regular, dest, _ctx), do: File.write!(dest, "image's own init")
  defp plant(:directory, dest, _ctx), do: File.mkdir!(dest)
end
