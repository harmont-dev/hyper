defmodule Hyper.Img.CreateTest do
  @moduledoc """
  `create/2` publishes across a mount boundary: when the store is on a different
  filesystem than the staged source, the atomic rename can't cross it and the
  copy-then-drop fallback must run. Kills a mutation that drops the `:exdev`
  arm — which would fail every publish whenever the scratch dir and the layer
  store are separate mounts (the normal NFS-store deployment).
  """
  use ExUnit.Case, async: false

  alias Hyper.Cfg.Dirs
  alias Hyper.Img

  @tag :external
  test "publishes a source that lives on a different filesystem than the store" do
    store = Path.join("/dev/shm", "hyper-img-test-#{System.unique_integer([:positive])}")
    Hyper.Cfg.Toml.put_cache(%{"img" => %{"store" => store}})

    on_exit(fn ->
      Hyper.Cfg.Toml.reload()
      File.rm_rf(store)
    end)

    # Source on the default tmp fs (ext4), store on tmpfs -> File.rename gives :exdev.
    src = Path.join(System.tmp_dir!(), "hyper-img-src-#{System.unique_integer([:positive])}.img")
    File.write!(src, :crypto.strong_rand_bytes(4096))

    assert {:ok, id} = Img.create(src, label: "cross-fs")
    assert File.exists?(Path.join(Dirs.layer_dir(), "layer_#{id}.img"))
    refute File.exists?(src), "the source must be consumed once published"
  end
end
