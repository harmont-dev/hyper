defmodule Hyper.Img.OciLoaderAgentTest do
  use ExUnit.Case, async: true

  import Bitwise

  @tmp Path.join(System.tmp_dir!(), "hyper-oci-agent-test")

  setup do
    File.rm_rf!(@tmp)
    File.mkdir_p!(@tmp)
    on_exit(fn -> File.rm_rf!(@tmp) end)
    :ok
  end

  test "stage_agent places an executable /hyper-init in the rootfs" do
    fake = Path.join(@tmp, "agent-bin")
    File.write!(fake, "#!/bin/true\n")

    assert :ok = Hyper.Img.OciLoader.stage_agent_from(@tmp, fake)

    dest = Path.join(@tmp, "hyper-init")
    assert File.exists?(dest)
    %File.Stat{mode: mode} = File.stat!(dest)
    assert (mode &&& 0o111) != 0, "hyper-init must be executable"
  end
end
