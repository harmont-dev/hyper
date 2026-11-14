defmodule Hyper.Img.OciLoaderHostileImageTest do
  @moduledoc """
  End-to-end laws of `OciLoader.load/2` against hostile OCI images served from
  a local registry, judged by what lands in the published ext4 (read back with
  `debugfs`) and on the host:

    * whatever an image plants at `/hyper-init` (absolute or relative symlink
      to a host file, symlink to a host dir or an absent host path, hard link
      escaping the root), the load never writes, truncates, creates or chmods
      anything on the host, and the published rootfs carries the agent's exact
      bytes as a regular 0755 `/hyper-init`;
    * the staged PID-1 binary is root-owned and not group/other-writable inside
      the guest, so no non-root guest uid can replace the guest's init;
    * the image's own ownership survives into the guest: an entry the layer
      records as `0:0` is root-owned in the ext4, one recorded as `1000:1000`
      stays `1000:1000`;
    * images following common distro conventions load: `/` at `0555`
      (Fedora/UBI) and `/etc/shadow` at `0000` (Fedora/RHEL), with those modes
      and bytes intact;
    * an image entry under an image-planted directory symlink never lands in
      the link's host target;
    * every load, success or failure, leaves no `hyper-oci-*` temp tree and no
      `.incoming-*` staged file behind; a `/hyper-init` directory is refused
      with the specific `{:bad_image, :hyper_init_is_a_directory}`.

  Needs docker (`registry:2`), skopeo, umoci, mke2fs, debugfs, python3 and
  Postgres: `mix test --include external test/hyper/img/oci_loader_hostile_image_test.exs`.
  """
  use ExUnit.Case, async: false

  import Bitwise

  alias Hyper.Cfg.Dirs
  alias Hyper.Img.OciLoader
  alias Hyper.Node.FireVMM.GuestAgent

  @moduletag :external
  @moduletag :tmp_dir
  @moduletag timeout: 600_000

  @canary_bytes "host canary\n"
  @canary_mode 0o640
  @shadow "root:*:1::::::\n"

  @tar_writer """
  import json, sys, tarfile, io
  out, spec = sys.argv[1], json.loads(sys.argv[2])
  kinds = {"dir": tarfile.DIRTYPE, "file": tarfile.REGTYPE, "symlink": tarfile.SYMTYPE,
           "hardlink": tarfile.LNKTYPE}
  with tarfile.open(out, "w", format=tarfile.PAX_FORMAT) as tar:
      for e in spec:
          info = tarfile.TarInfo(e["name"])
          info.type = kinds[e["type"]]
          info.mode = e.get("mode", 0o644)
          info.uid = info.gid = e.get("owner", 0)
          info.linkname = e.get("link", "")
          data = e.get("data", "").encode()
          info.size = len(data) if e["type"] == "file" else 0
          tar.addfile(info, io.BytesIO(data) if info.size else None)
  """

  setup_all do
    {id, 0} = System.cmd("docker", ["run", "-d", "--rm", "-p", "127.0.0.1::5000", "registry:2"])
    container = String.trim(id)
    {port_line, 0} = System.cmd("docker", ["port", container, "5000/tcp"])
    registry = port_line |> String.split("\n", trim: true) |> hd() |> String.trim()
    wait_for_registry(registry, 50)

    conf_home =
      Path.join(System.tmp_dir!(), "hyper-hostile-reg-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(conf_home, ".config/containers"))

    File.write!(
      Path.join(conf_home, ".config/containers/registries.conf"),
      "[[registry]]\nlocation = \"#{registry}\"\ninsecure = true\n"
    )

    on_exit(fn ->
      System.cmd("docker", ["rm", "-f", container], stderr_to_stdout: true)
      File.rm_rf(conf_home)
    end)

    {:ok, arch} = Sys.Arch.current()
    %{registry: registry, conf_home: conf_home, agent: File.read!(GuestAgent.path(arch))}
  end

  setup %{tmp_dir: tmp} do
    host = Path.join(tmp, "host")
    host_dir = Path.join(host, "dir")
    File.mkdir_p!(host_dir)
    canary = Path.join(host, "canary")
    File.write!(canary, @canary_bytes)
    File.chmod!(canary, @canary_mode)

    loader_tmp = Path.join(tmp, "loader-tmp")
    File.mkdir_p!(loader_tmp)
    saved = Map.new(["TMPDIR", "HOME"], &{&1, System.get_env(&1)})
    on_exit(fn -> restore_env(saved) end)

    %{
      host: host,
      host_dir: host_dir,
      canary: canary,
      absent: Path.join(host, "absent"),
      loader_tmp: loader_tmp,
      saved_env: saved
    }
  end

  defp restore_env(saved) do
    Enum.each(saved, fn
      {k, nil} -> System.delete_env(k)
      {k, v} -> System.put_env(k, v)
    end)
  end

  defp wait_for_registry(_registry, 0), do: flunk("local registry never came up")

  defp wait_for_registry(registry, n) do
    case System.cmd("curl", ["-fsS", "http://#{registry}/v2/"], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      _ ->
        Process.sleep(100)
        wait_for_registry(registry, n - 1)
    end
  end

  defp base_layer(overrides \\ %{}) do
    [
      %{name: ".", type: "dir", mode: 0o755},
      %{name: "etc", type: "dir", mode: 0o755},
      %{name: "etc/shadow", type: "file", mode: 0o640, data: @shadow},
      %{name: "home", type: "dir", mode: 0o755},
      %{name: "home/app", type: "dir", mode: 0o700, owner: 1000},
      %{name: "home/app/notes", type: "file", mode: 0o600, owner: 1000, data: "mine\n"}
    ]
    |> Enum.map(fn e -> Map.merge(e, Map.get(overrides, e.name, %{})) end)
  end

  defp push!(ctx, name, entries) do
    work = Path.join(ctx.tmp_dir, "build-#{name}")
    File.mkdir_p!(work)
    layer = Path.join(work, "layer.tar")
    {_, 0} = System.cmd("python3", ["-I", "-c", @tar_writer, layer, JSON.encode!(entries)])

    layout = Path.join(work, "layout")
    umoci = OciLoader.Umoci.bin()
    {_, 0} = System.cmd(umoci, ["init", "--layout", layout], stderr_to_stdout: true)
    {_, 0} = System.cmd(umoci, ["new", "--image", "#{layout}:t"], stderr_to_stdout: true)

    {_, 0} =
      System.cmd(umoci, ["raw", "add-layer", "--image", "#{layout}:t", layer],
        stderr_to_stdout: true
      )

    ref = "#{ctx.registry}/#{name}:t"

    {out, status} =
      System.cmd(
        "skopeo",
        ["copy", "--dest-tls-verify=false", "oci:#{layout}:t", "docker://#{ref}"],
        stderr_to_stdout: true
      )

    assert status == 0, out
    ref
  end

  defp load(ctx, ref) do
    incoming_before = incoming()
    System.put_env("TMPDIR", ctx.loader_tmp)
    System.put_env("HOME", ctx.conf_home)
    result = OciLoader.load(ref)
    restore_env(ctx.saved_env)

    refute match?({:error, {:skopeo_failed, _, _}}, result), inspect(result)
    assert File.ls!(ctx.loader_tmp) == [], "load left a temp tree: #{inspect(result)}"
    assert incoming() == incoming_before, "load left a staged .incoming file"
    result
  end

  defp incoming do
    case File.ls(Dirs.layer_dir()) do
      {:ok, names} -> names |> Enum.filter(&String.starts_with?(&1, ".incoming-")) |> Enum.sort()
      {:error, _} -> []
    end
  end

  defp image_path(id), do: Path.join(Dirs.layer_dir(), "layer_#{id}.img")

  defp ext4_stat(img, path) do
    {out, 0} = System.cmd("debugfs", ["-R", "stat #{path}", img], stderr_to_stdout: true)
    [_, type, mode] = Regex.run(~r/Type: (\w+)\s+Mode:\s+(\d+)/, out)
    [_, uid, gid] = Regex.run(~r/User:\s+(\d+)\s+Group:\s+(\d+)/, out)

    %{
      type: type,
      mode: String.to_integer(mode, 8),
      uid: String.to_integer(uid),
      gid: String.to_integer(gid)
    }
  end

  defp ext4_read(ctx, img, path) do
    out = Path.join(ctx.tmp_dir, "dump-#{System.unique_integer([:positive])}")
    {_, 0} = System.cmd("debugfs", ["-R", "dump #{path} #{out}", img], stderr_to_stdout: true)
    File.read!(out)
  end

  defp assert_host_untouched(ctx) do
    assert File.read!(ctx.canary) == @canary_bytes
    assert band(File.lstat!(ctx.canary).mode, 0o7777) == @canary_mode
    assert Enum.sort(File.ls!(ctx.host)) == ["canary", "dir"]
    assert File.ls!(ctx.host_dir) == []
  end

  defp assert_agent_staged(ctx, id) do
    img = image_path(id)
    assert %{type: "regular", mode: mode} = ext4_stat(img, "/hyper-init")
    assert band(mode, 0o7777) == 0o755
    assert ext4_read(ctx, img, "/hyper-init") == ctx.agent
  end

  defp rel_climb(abs), do: String.duplicate("../", 64) <> String.trim_leading(abs, "/")

  defp plant_entry(:abs_symlink, ctx),
    do: %{name: "hyper-init", type: "symlink", link: ctx.canary}

  defp plant_entry(:rel_symlink, ctx),
    do: %{name: "hyper-init", type: "symlink", link: rel_climb(ctx.canary)}

  defp plant_entry(:dir_symlink, ctx),
    do: %{name: "hyper-init", type: "symlink", link: ctx.host_dir}

  defp plant_entry(:absent_symlink, ctx),
    do: %{name: "hyper-init", type: "symlink", link: ctx.absent}

  defp plant_entry(:hardlink_escape, ctx),
    do: %{name: "hyper-init", type: "hardlink", link: rel_climb(ctx.canary)}

  for plant <- [:abs_symlink, :rel_symlink, :dir_symlink, :absent_symlink] do
    test "an image whose /hyper-init is #{plant} stages the agent and never reaches the host",
         ctx do
      ref =
        push!(ctx, "plant-#{unquote(plant)}", base_layer() ++ [plant_entry(unquote(plant), ctx)])

      result = load(ctx, ref)

      assert_host_untouched(ctx)
      assert {:ok, id} = result
      assert_agent_staged(ctx, id)
    end
  end

  test "an image whose /hyper-init is a hard link escaping the root never reaches the host",
       ctx do
    ref = push!(ctx, "plant-hardlink", base_layer() ++ [plant_entry(:hardlink_escape, ctx)])
    result = load(ctx, ref)

    assert_host_untouched(ctx)

    case result do
      {:ok, id} -> assert_agent_staged(ctx, id)
      {:error, {:umoci_failed, _, _}} -> :ok
    end
  end

  test "an entry under an image-planted directory symlink never lands in the host target", ctx do
    entries =
      base_layer() ++
        [
          %{name: "escape", type: "symlink", link: ctx.host_dir},
          %{name: "escape/pwned", type: "file", mode: 0o755, data: "pwned\n"}
        ]

    ref = push!(ctx, "parent-symlink", entries)
    result = load(ctx, ref)

    assert_host_untouched(ctx)

    case result do
      {:ok, id} -> assert_agent_staged(ctx, id)
      {:error, {:umoci_failed, _, _}} -> :ok
    end
  end

  test "the staged init is root-owned and not writable by any non-root guest uid", ctx do
    ref = push!(ctx, "owner-init", base_layer())
    assert {:ok, id} = load(ctx, ref)

    assert %{uid: 0, gid: 0, mode: mode} = ext4_stat(image_path(id), "/hyper-init")
    assert band(mode, 0o022) == 0
  end

  test "the image's recorded ownership survives into the guest rootfs", ctx do
    ref = push!(ctx, "owner-tree", base_layer())
    assert {:ok, id} = load(ctx, ref)
    img = image_path(id)

    owners =
      for path <- ["/", "/etc", "/etc/shadow", "/home/app", "/home/app/notes"],
          into: %{},
          do: {path, Map.take(ext4_stat(img, path), [:uid, :gid])}

    assert owners == %{
             "/" => %{uid: 0, gid: 0},
             "/etc" => %{uid: 0, gid: 0},
             "/etc/shadow" => %{uid: 0, gid: 0},
             "/home/app" => %{uid: 1000, gid: 1000},
             "/home/app/notes" => %{uid: 1000, gid: 1000}
           }
  end

  test "an image whose root directory is 0555 loads with the agent staged", ctx do
    ref = push!(ctx, "ro-root", base_layer(%{"." => %{mode: 0o555}}))

    assert {:ok, id} = load(ctx, ref)
    assert_agent_staged(ctx, id)
  end

  test "an image with a 0000 /etc/shadow loads with the shadow's mode and bytes intact", ctx do
    ref = push!(ctx, "shadow-0000", base_layer(%{"etc/shadow" => %{mode: 0o000}}))

    assert {:ok, id} = load(ctx, ref)
    img = image_path(id)
    assert band(ext4_stat(img, "/etc/shadow").mode, 0o7777) == 0
    assert ext4_read(ctx, img, "/etc/shadow") == @shadow
  end

  test "an image whose /hyper-init is a directory is refused with the specific error", ctx do
    entries =
      base_layer() ++
        [
          %{name: "hyper-init", type: "dir", mode: 0o755},
          %{name: "hyper-init/payload", type: "file", data: "x"}
        ]

    ref = push!(ctx, "init-dir", entries)

    assert {:error, {:bad_image, :hyper_init_is_a_directory}} = load(ctx, ref)
    assert_host_untouched(ctx)
  end

  test "a failing load over 0000 directories leaves no temp tree or staged file behind", ctx do
    entries =
      base_layer() ++
        [
          %{name: "hyper-init", type: "dir", mode: 0o000},
          %{name: "locked", type: "dir", mode: 0o000},
          %{name: "locked/inner", type: "dir", mode: 0o000},
          %{name: "locked/inner/f", type: "file", mode: 0o000, data: "x"}
        ]

    ref = push!(ctx, "locked-dirs", entries)

    assert {:error, {:bad_image, :hyper_init_is_a_directory}} = load(ctx, ref)
    assert_host_untouched(ctx)
  end
end
