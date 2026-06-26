defmodule Hyper.Cfg.BudgetTest do
  use ExUnit.Case, async: false

  alias Hyper.Cfg.Budget
  alias Hyper.Cfg.Toml

  setup do
    Application.delete_env(:hyper, Budget)
    Toml.put_cache(%{})
    on_exit(fn ->
      Application.delete_env(:hyper, Budget)
      Toml.reload()
    end)
    :ok
  end

  test "loads Unit values from config.exs terms" do
    Application.put_env(:hyper, Budget,
      mem_max: Unit.Information.gib(4),
      disk_max: Unit.Information.gib(64),
      cpu_max_load: 0.8,
      disk_bw_cap: Unit.Bandwidth.gibps(1),
      disk_bw_max_load: 0.8,
      net_bw_cap: Unit.Bandwidth.gibps(1),
      net_bw_max_load: 0.8
    )

    assert {:ok, cfg} = Budget.load()
    assert cfg.mem_max == Unit.Information.gib(4)
    assert cfg.net_bw_cap == Unit.Bandwidth.gibps(1)
  end

  test "loads the same values from a [budget] toml table as strings" do
    Toml.put_cache(%{
      "budget" => %{
        "mem_max" => "4GiB",
        "disk_max" => "64GiB",
        "cpu_max_load" => 0.8,
        "cpu_max_cap" => 4.0,
        "disk_bw_cap" => "1GiBps",
        "disk_bw_max_load" => 0.8,
        "net_bw_cap" => "1GiBps",
        "net_bw_max_load" => 0.8
      }
    })

    assert {:ok, cfg} = Budget.load()
    assert cfg.mem_max == Unit.Information.gib(4)
    assert cfg.disk_bw_cap == Unit.Bandwidth.gibps(1)
    assert cfg.cpu_max_cap == 4.0
  end

  test "config.exs wins over the toml table" do
    Toml.put_cache(%{
      "budget" => %{
        "mem_max" => "1GiB",
        "disk_max" => "64GiB",
        "cpu_max_load" => 0.8,
        "disk_bw_cap" => "1GiBps",
        "disk_bw_max_load" => 0.8,
        "net_bw_cap" => "1GiBps",
        "net_bw_max_load" => 0.8
      }
    })

    Application.put_env(:hyper, Budget, mem_max: Unit.Information.gib(8))
    {:ok, cfg} = Budget.load()
    assert cfg.mem_max == Unit.Information.gib(8)
  end

  test "a missing required field is an error, not a crash" do
    assert {:error, _} = Budget.load()
  end
end
