defmodule Hyper.Cfg.ImgTest do
  use ExUnit.Case, async: false

  alias Hyper.Cfg.Dirs
  alias Hyper.Cfg.Img
  alias Hyper.Cfg.Toml

  setup do
    Application.delete_env(:hyper, Img)
    Toml.put_cache(%{})

    on_exit(fn ->
      Application.delete_env(:hyper, Img)
      Toml.reload()
    end)

    :ok
  end

  test "store defaults to <work_dir>/layers and Dirs.layer_dir delegates" do
    assert Img.store() == Path.join(Dirs.work_dir(), "layers")
    assert Dirs.layer_dir() == Img.store()
  end

  test "store reads [img] store from toml and config.exs wins" do
    Toml.put_cache(%{"img" => %{"store" => "/mnt/layers"}})
    assert Img.store() == "/mnt/layers"
    Application.put_env(:hyper, Img, store: "/exs/layers")
    assert Img.store() == "/exs/layers"
  end
end
