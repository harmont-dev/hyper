defmodule Hyper.Cfg.GcTest do
  use ExUnit.Case, async: false

  alias Hyper.Cfg.Gc
  alias Hyper.Cfg.Toml

  setup do
    Application.delete_env(:hyper, Gc)
    Toml.put_cache(%{})

    on_exit(fn ->
      Application.delete_env(:hyper, Gc)
      Toml.reload()
    end)

    :ok
  end

  test "defaults when nothing configured" do
    cfg = Gc.load()
    assert cfg.batch_size == 200
    assert cfg.sweep_interval == Unit.Time.s(60)
    assert cfg.timeout == Unit.Time.s(5)
    assert cfg.grace_period == Unit.Time.s(3600)
  end

  test "reads durations from [img.gc] toml as strings" do
    Toml.put_cache(%{
      "img" => %{"gc" => %{"sweep_interval" => "30s", "grace_period" => "1h", "batch_size" => 50}}
    })

    cfg = Gc.load()
    assert cfg.sweep_interval == Unit.Time.s(30)
    assert cfg.grace_period == Unit.Time.s(3600)
    assert cfg.batch_size == 50
  end

  test "config.exs Unit term wins over toml string" do
    Toml.put_cache(%{"img" => %{"gc" => %{"sweep_interval" => "30s"}}})
    Application.put_env(:hyper, Gc, sweep_interval: Unit.Time.s(90))
    assert Gc.load().sweep_interval == Unit.Time.s(90)
  end
end
