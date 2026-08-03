defmodule Hyper.Cfg.FleetTest do
  @moduledoc """
  What `Hyper.Cfg.Fleet` promises is *layering*, not storage:

    * a knob resolves `config.exs` -> the `[fleet]` TOML table -> its built-in
      default, and a value present in a lower layer does not disturb its
      siblings;
    * `provider` and `provider_opts` are `config.exs`-only, so a `[fleet]` TOML
      table can never redirect Hyper at a different provider or a different set
      of credentials;
    * a value that cannot be honoured fails `load/0` naming the offending key,
      rather than reaching the Governor and crashing its first tick.
  """

  use ExUnit.Case, async: false

  alias Hyper.Cfg.Fleet
  alias Hyper.Cfg.Toml
  alias Hyper.Cluster.Fleet.Provider.Static

  setup do
    Application.delete_env(:hyper, Fleet)
    Toml.put_cache(%{})

    on_exit(fn ->
      Application.delete_env(:hyper, Fleet)
      Toml.reload()
      # load/0 caches the struct; erase it so no later test observes this
      # test's fleet by accident.
      :persistent_term.erase(Fleet)
    end)

    :ok
  end

  test "load/0 with no app env and no TOML table returns the documented built-in defaults" do
    assert {:ok, config} = Fleet.load()

    assert config == %Fleet{
             provider: Static,
             provider_opts: [],
             min_nodes: 0,
             max_nodes: nil,
             target_headroom: 1,
             reference_type: :base,
             cooldown: Unit.Time.s(120),
             provision_deadline: Unit.Time.s(600),
             nodedown_grace: Unit.Time.s(300),
             drain_deadline: Unit.Time.s(1800)
           }
  end

  test "a [fleet] TOML table overrides the defaults it names, and only those" do
    Toml.put_cache(%{
      "fleet" => %{
        "min_nodes" => 2,
        "max_nodes" => 10,
        "cooldown" => "30s",
        "reference_type" => "deca"
      }
    })

    assert {:ok, config} = Fleet.load()
    assert config.min_nodes == 2
    assert config.max_nodes == 10
    assert config.cooldown == Unit.Time.s(30)
    assert config.reference_type == :deca
    assert config.target_headroom == 1
    assert config.drain_deadline == Unit.Time.s(1800)
  end

  test "an app-env override (config.exs) wins over a conflicting TOML value" do
    Toml.put_cache(%{"fleet" => %{"min_nodes" => 2, "cooldown" => "30s"}})
    Application.put_env(:hyper, Fleet, min_nodes: 5, cooldown: Unit.Time.s(90))

    assert {:ok, config} = Fleet.load()
    assert config.min_nodes == 5
    assert config.cooldown == Unit.Time.s(90)
  end

  test "provider and provider_opts are config.exs-only and ignore the TOML layer" do
    Toml.put_cache(%{
      "fleet" => %{"provider" => "Elixir.Some.Other.Provider", "provider_opts" => %{}}
    })

    assert {:ok, defaulted} = Fleet.load()
    assert defaulted.provider == Static
    assert defaulted.provider_opts == []

    Application.put_env(:hyper, Fleet, provider: Static, provider_opts: [nodes: [:a@host]])

    assert {:ok, configured} = Fleet.load()
    assert configured.provider_opts == [nodes: [:a@host]]
  end

  # Refusal contracts: each bad value must fail load/0 with an error naming the
  # offending key, never silently coerce and never raise. Table-driven — one
  # assertion shape, rows differ only in the bad env and expected error.
  @bad_fleets [
    {[provider: "Static"], {:error, {:bad_value, :provider, "Static"}}},
    {[provider_opts: %{nodes: []}], {:error, {:bad_value, :provider_opts, %{nodes: []}}}},
    {[provider_opts: [:nodes]], {:error, {:bad_value, :provider_opts, [:nodes]}}},
    {[min_nodes: -1], {:error, {:bad_value, :min_nodes, -1}}},
    {[max_nodes: 0], {:error, {:bad_value, :max_nodes, 0}}},
    {[min_nodes: 4, max_nodes: 2], {:error, {:bad_range, :max_nodes, {4, 2}}}},
    {[target_headroom: 1.5], {:error, {:bad_value, :target_headroom, 1.5}}},
    {[reference_type: :enormous], {:error, {:bad_value, :reference_type, :enormous}}},
    {[cooldown: 30], {:error, {:bad_value, :cooldown, 30}}},
    {[drain_deadline: "30 fortnights"], {:error, {:bad_value, :drain_deadline, "30 fortnights"}}}
  ]

  for {env, expected} <- @bad_fleets do
    @env env
    @expected expected
    test "load/0 rejects #{inspect(@env)} with #{inspect(@expected)}" do
      Application.put_env(:hyper, Fleet, @env)
      assert Fleet.load() == @expected
    end
  end
end
