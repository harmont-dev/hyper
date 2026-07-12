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
      # load/0 caches the struct; erase it so no later test observes this
      # test's budget by accident.
      :persistent_term.erase(Budget)
    end)

    :ok
  end

  test "load/0 with no app env and no TOML table returns the documented built-in defaults" do
    assert {:ok, config} = Budget.load()

    assert config == %Budget{
             mem_max: Unit.Information.gib(4),
             disk_max: Unit.Information.gib(4),
             cpu_max_load: 0.8,
             cpu_max_cap: 4.0,
             disk_bw_cap: Unit.Bandwidth.gibps(1),
             disk_bw_max_load: 0.8,
             net_bw_cap: Unit.Bandwidth.gibps(1),
             net_bw_max_load: 0.8
           }
  end

  test "a [budget] TOML table overrides the built-in default" do
    Toml.put_cache(%{"budget" => %{"cpu_max_load" => 0.5, "mem_max" => "2GiB"}})

    assert {:ok, config} = Budget.load()
    assert config.cpu_max_load == 0.5
    assert config.mem_max == Unit.Information.gib(2)
    # Fields absent from the TOML table still fall back to their defaults.
    assert config.disk_max == Unit.Information.gib(4)
  end

  test "an app-env override (config.exs) wins over a conflicting TOML value" do
    Toml.put_cache(%{"budget" => %{"cpu_max_load" => 0.5}})
    Application.put_env(:hyper, Budget, cpu_max_load: 0.9)

    assert {:ok, config} = Budget.load()
    assert config.cpu_max_load == 0.9
  end

  test "cpu_max_cap can be explicitly disabled via app env, overriding its default" do
    Application.put_env(:hyper, Budget, cpu_max_cap: nil)

    assert {:ok, config} = Budget.load()
    assert config.cpu_max_cap == nil
  end

  # Refusal contracts on bad budget values: each must fail load with a specific
  # error naming the offending key, never silently coerce or crash. Table-driven:
  # one assertion shape, rows differ only in the bad env and expected error.
  @bad_budgets [
    {[mem_max: 123], {:error, {:bad_value, :mem_max, 123}}},
    {[mem_max: "notabytes"], {:error, {:bad_value, :mem_max, "notabytes"}}},
    {[cpu_max_load: "high"], {:error, {:not_a_number, :cpu_max_load, "high"}}}
  ]

  for {env, expected} <- @bad_budgets do
    @env env
    @expected expected
    test "load/0 rejects #{inspect(@env)} with #{inspect(@expected)}" do
      Application.put_env(:hyper, Budget, @env)
      assert @expected = Budget.load()
    end
  end
end
