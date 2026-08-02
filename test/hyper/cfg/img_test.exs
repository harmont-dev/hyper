defmodule Hyper.Cfg.ImgTest do
  use ExUnit.Case, async: false

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

  describe "thin pool sizing" do
    test "falls back to the documented built-in defaults" do
      assert Img.thin_pool_data_size() == Unit.Information.gib(64)
      assert Img.thin_pool_meta_size() == Unit.Information.gib(1)
    end

    test "an [img] TOML table overrides the built-in default" do
      Toml.put_cache(%{
        "img" => %{"thin_pool_data_size" => "128GiB", "thin_pool_meta_size" => "2GiB"}
      })

      assert Img.thin_pool_data_size() == Unit.Information.gib(128)
      assert Img.thin_pool_meta_size() == Unit.Information.gib(2)
    end

    test "an app-env override (config.exs) wins over a conflicting TOML value" do
      Toml.put_cache(%{"img" => %{"thin_pool_data_size" => "128GiB"}})
      Application.put_env(:hyper, Img, thin_pool_data_size: Unit.Information.gib(256))

      assert Img.thin_pool_data_size() == Unit.Information.gib(256)
    end

    test "a malformed size raises rather than silently sizing the pool wrong" do
      Toml.put_cache(%{"img" => %{"thin_pool_data_size" => "128 gigglebytes"}})

      assert_raise ArgumentError, fn -> Img.thin_pool_data_size() end
    end
  end
end
