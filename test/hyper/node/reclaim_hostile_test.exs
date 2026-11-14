defmodule Hyper.Node.ReclaimHostileTest do
  @moduledoc """
  `Hyper.Node.Reclaim.reclaim_sockets/0` against a socket dir whose entries are
  not what their names claim (#135 widened the sweep to Firecracker socket pins).

  Laws:

  - the sweep removes names, never what they point at: a symlink named like a
    relay socket or a socket pin is unlinked and its target survives untouched;
  - an entry it cannot remove (a directory wearing a pin's name) is left in
    place and the sweep still finishes, removing every other stale socket;
  - best-effort: a socket dir the node cannot make private is logged, never a
    raise that takes boot down.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Hyper.Node.Reclaim

  setup do
    original = Hyper.Cfg.Toml.reload()

    tmp =
      Path.join(System.tmp_dir!(), "hyper-reclaim-hostile-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    Hyper.Cfg.Toml.put_cache(Map.put(original, "work_dir", tmp))

    on_exit(fn ->
      Hyper.Cfg.Toml.put_cache(original)
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp, socket_dir: Path.join(tmp, "socks")}
  end

  test "symlinks named like stale sockets are unlinked, their targets never touched",
       %{tmp: tmp, socket_dir: dir} do
    File.mkdir_p!(dir)
    victims = Path.join(tmp, "victims")
    File.mkdir_p!(victims)

    names = ["grpc-v1.sock", "fc-v1-api.socket", "fc-v1-vsock.sock"]

    for name <- names do
      victim = Path.join(victims, name)
      File.write!(victim, "keep #{name}")
      File.chmod!(victim, 0o644)
      File.ln_s!(victim, Path.join(dir, name))
    end

    Reclaim.reclaim_sockets()

    assert {File.ls!(dir), Enum.map(names, &File.read!(Path.join(victims, &1)))} ==
             {[], Enum.map(names, &"keep #{&1}")}

    assert Enum.map(names, &(File.stat!(Path.join(victims, &1)).mode |> Bitwise.band(0o777))) ==
             [0o644, 0o644, 0o644]
  end

  test "an entry that cannot be removed is kept and the rest of the sweep still runs",
       %{socket_dir: dir} do
    File.mkdir_p!(Path.join([dir, "fc-v1-api.socket", "inside"]))
    File.write!(Path.join(dir, "fc-v2-vsock.sock"), "")
    File.write!(Path.join(dir, "grpc-v3.sock"), "")

    capture_log(fn -> assert Reclaim.reclaim_sockets() == :ok end)

    assert File.ls!(dir) |> Enum.sort() == ["fc-v1-api.socket"]
    assert File.dir?(Path.join([dir, "fc-v1-api.socket", "inside"]))
  end

  test "a socket dir the node cannot chmod is logged, not raised", %{socket_dir: dir} do
    File.ln_s!("/usr", dir)
    before = File.stat!("/usr").mode

    result =
      try do
        {result, _log} = with_log(&Reclaim.reclaim_sockets/0)
        result
      rescue
        e -> {:raised, e.__struct__}
      end

    assert {result, File.stat!("/usr").mode} == {:ok, before}
  end
end
