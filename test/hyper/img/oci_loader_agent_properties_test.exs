defmodule Hyper.Img.OciLoaderAgentPropertiesTest do
  @moduledoc """
  Laws of `OciLoader.stage_agent_from/2` over every shape an image can leave at
  `/hyper-init` (absent, regular file of any mode, symlink to a host file / host
  dir / dangling host path / itself / a chain, hard link to a host file or to a
  sibling inside the image, fifo):

    * staging succeeds and leaves a fresh regular, mode-0755 `/hyper-init`
      holding exactly the agent's bytes;
    * nothing outside `/hyper-init` changes: host files keep their bytes and
      mode, absent host paths stay absent, host dirs stay empty, and a sibling
      the image hard-linked to `/hyper-init` keeps its bytes (unlinking the name
      never truncates the shared inode);
    * staging is idempotent: a second stage over the first gives the same tree;
    * an image whose `/hyper-init` is a directory is refused and left as-is;
    * under a concurrent adversary that keeps re-planting `/hyper-init` as a
      symlink to a host file, no stage ever writes or chmods the host file
      (each stage either succeeds or fails, never writes through).
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise

  alias Hyper.Img.OciLoader

  @moduletag :tmp_dir

  @host_bytes "host secret\n"
  @host_mode 0o600
  @sibling_bytes "busybox\n"

  defp plant do
    StreamData.one_of([
      StreamData.constant(:none),
      StreamData.tuple(
        {StreamData.constant(:regular), StreamData.binary(max_length: 64),
         StreamData.member_of([0o000, 0o644, 0o4755, 0o111, 0o777])}
      ),
      StreamData.member_of([
        {:symlink, :host_file},
        {:symlink, :host_absent},
        {:symlink, :host_dir},
        {:symlink, :relative_host_file},
        {:symlink, :self},
        {:symlink, :chain},
        {:symlink, :sibling},
        {:hardlink, :host_file},
        {:hardlink, :sibling},
        :fifo
      ])
    ])
  end

  defp agent_bytes do
    StreamData.frequency([
      {9, StreamData.binary(max_length: 4096)},
      {1, StreamData.map(StreamData.integer(65_536..300_000), &:crypto.strong_rand_bytes/1)}
    ])
  end

  defp fresh_world(tmp) do
    root = Path.join(tmp, "w#{System.unique_integer([:positive])}")
    rootfs = Path.join(root, "rootfs")
    host = Path.join(root, "host")
    host_dir = Path.join(host, "dir")
    File.mkdir_p!(rootfs)
    File.mkdir_p!(host_dir)

    host_file = Path.join(host, "existing")
    File.write!(host_file, @host_bytes)
    File.chmod!(host_file, @host_mode)

    sibling = Path.join(rootfs, "busybox")
    File.write!(sibling, @sibling_bytes)

    %{
      root: root,
      rootfs: rootfs,
      dest: Path.join(rootfs, "hyper-init"),
      host_file: host_file,
      host_dir: host_dir,
      host_absent: Path.join(host, "absent"),
      sibling: sibling,
      agent: Path.join(root, "agent-bin")
    }
  end

  defp plant!(:none, _w), do: :ok

  defp plant!({:regular, bytes, mode}, w) do
    File.write!(w.dest, bytes)
    File.chmod!(w.dest, mode)
  end

  defp plant!({:symlink, :host_file}, w), do: File.ln_s!(w.host_file, w.dest)
  defp plant!({:symlink, :host_absent}, w), do: File.ln_s!(w.host_absent, w.dest)
  defp plant!({:symlink, :host_dir}, w), do: File.ln_s!(w.host_dir, w.dest)
  defp plant!({:symlink, :relative_host_file}, w), do: File.ln_s!("../host/existing", w.dest)
  defp plant!({:symlink, :self}, w), do: File.ln_s!("hyper-init", w.dest)
  defp plant!({:symlink, :sibling}, w), do: File.ln_s!("busybox", w.dest)

  defp plant!({:symlink, :chain}, w) do
    hop = Path.join(w.rootfs, "hop")
    File.ln_s!(w.host_file, hop)
    File.ln_s!("hop", w.dest)
  end

  defp plant!({:hardlink, :host_file}, w), do: File.ln!(w.host_file, w.dest)
  defp plant!({:hardlink, :sibling}, w), do: File.ln!(w.sibling, w.dest)
  defp plant!(:fifo, w), do: {_, 0} = System.cmd("mkfifo", [w.dest])

  defp assert_staged(w, agent) do
    assert {:ok, %File.Stat{type: :regular, mode: mode, links: 1}} = File.lstat(w.dest)
    assert band(mode, 0o7777) == 0o755
    assert File.read!(w.dest) == agent
  end

  defp assert_outside_untouched(w) do
    assert File.read!(w.host_file) == @host_bytes
    assert band(File.lstat!(w.host_file).mode, 0o7777) == @host_mode
    refute File.exists?(w.host_absent)
    assert File.ls!(w.host_dir) == []
    assert File.read!(w.sibling) == @sibling_bytes
  end

  property "stages a fresh 0755 agent over any image-planted /hyper-init without touching anything else",
           %{tmp_dir: tmp} do
    check all(planted <- plant(), agent <- agent_bytes(), max_runs: 150) do
      w = fresh_world(tmp)
      File.write!(w.agent, agent)
      plant!(planted, w)

      assert :ok = OciLoader.stage_agent_from(w.rootfs, w.agent), inspect(planted)
      assert_staged(w, agent)
      assert_outside_untouched(w)
    end
  end

  property "staging twice is the same as staging once", %{tmp_dir: tmp} do
    check all(planted <- plant(), agent <- agent_bytes(), max_runs: 50) do
      w = fresh_world(tmp)
      File.write!(w.agent, agent)
      plant!(planted, w)

      assert :ok = OciLoader.stage_agent_from(w.rootfs, w.agent)
      listing = File.ls!(w.rootfs) |> Enum.sort()
      assert :ok = OciLoader.stage_agent_from(w.rootfs, w.agent)

      assert Enum.sort(File.ls!(w.rootfs)) == listing
      assert_staged(w, agent)
      assert_outside_untouched(w)
    end
  end

  property "a non-empty /hyper-init directory is refused and left exactly as the image had it",
           %{tmp_dir: tmp} do
    check all(entries <- StreamData.list_of(StreamData.binary(min_length: 1), max_length: 3)) do
      w = fresh_world(tmp)
      File.write!(w.agent, "agent")
      File.mkdir!(w.dest)

      entries
      |> Enum.with_index()
      |> Enum.each(fn {bytes, i} -> File.write!(Path.join(w.dest, "f#{i}"), bytes) end)

      assert {:error, {:bad_image, :hyper_init_is_a_directory}} =
               OciLoader.stage_agent_from(w.rootfs, w.agent)

      assert File.dir?(w.dest)
      assert length(File.ls!(w.dest)) == length(entries)
      assert_outside_untouched(w)
    end
  end

  test "an agent source that is a directory fails the stage and creates no /hyper-init", %{
    tmp_dir: tmp
  } do
    w = fresh_world(tmp)
    File.mkdir!(w.agent)
    File.ln_s!(w.host_file, w.dest)

    assert {:error, _} = OciLoader.stage_agent_from(w.rootfs, w.agent)
    assert {:error, :enoent} = File.lstat(w.dest)
    assert_outside_untouched(w)
  end

  test "an image whose root directory is read-only (0555) still gets the agent staged", %{
    tmp_dir: tmp
  } do
    w = fresh_world(tmp)
    File.write!(w.agent, "agent")
    File.chmod!(w.rootfs, 0o555)
    on_exit(fn -> File.chmod(w.rootfs, 0o755) end)

    result = OciLoader.stage_agent_from(w.rootfs, w.agent)
    File.chmod!(w.rootfs, 0o755)

    assert :ok = result
    assert_staged(w, "agent")
  end

  test "a concurrent link-planting adversary can never make a stage write or chmod a host file",
       %{tmp_dir: tmp} do
    w = fresh_world(tmp)
    agent = :crypto.strong_rand_bytes(256 * 1024)
    File.write!(w.agent, agent)

    racer =
      spawn_link(fn ->
        plant_forever = fn loop ->
          _ = File.rm(w.dest)
          _ = File.ln_s(w.host_file, w.dest)
          loop.(loop)
        end

        plant_forever.(plant_forever)
      end)

    outcomes =
      for _ <- 1..2000 do
        result = OciLoader.stage_agent_from(w.rootfs, w.agent)
        assert File.read!(w.host_file) == @host_bytes

        assert band(File.lstat!(w.host_file).mode, 0o7777) == @host_mode,
               "host file chmodded through a re-planted /hyper-init after #{inspect(result)}"

        result
      end

    Process.unlink(racer)
    Process.exit(racer, :kill)

    assert Enum.all?(outcomes, &(&1 == :ok or match?({:error, _}, &1)))
    assert_outside_untouched(w)
  end
end
