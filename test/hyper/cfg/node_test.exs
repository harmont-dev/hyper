defmodule Hyper.Cfg.NodeTest do
  @moduledoc """
  `Hyper.Cfg.Node` decides whether this machine starts `Hyper.Node` at all, so
  what it promises is *layering* and *refusal*:

    * `config.exs` beats the `[node]` TOML table beats the built-in `:host`, and
      the default is `:host` precisely so an existing deployment that names no
      role keeps behaving exactly as it did;
    * TOML carries strings and `config.exs` carries atoms, and both spellings of
      each role resolve to the same value;
    * anything else raises rather than being guessed at. Silently reading an
      unrecognised role as `:control` would take a working Firecracker host out
      of the cluster on a typo, and reading it as `:host` would make a machine
      with no KVM refuse to boot — there is no safe direction to guess in.
  """

  use ExUnit.Case, async: false

  alias Hyper.Cfg.Node, as: Config
  alias Hyper.Cfg.Toml

  setup do
    Application.delete_env(:hyper, Config)
    Toml.put_cache(%{})

    on_exit(fn ->
      Application.delete_env(:hyper, Config)
      Toml.reload()
    end)

    :ok
  end

  # One assertion shape over the layers: whichever source is highest wins, and
  # the atom/string spellings are interchangeable.
  @cases [
    {"nothing set anywhere", nil, nil, :host},
    {"a TOML role", nil, "control", :control},
    {"a TOML host role", nil, "host", :host},
    {"an app-env role", :control, nil, :control},
    {"app env overriding TOML", :control, "host", :control},
    {"app env overriding TOML the other way", :host, "control", :host}
  ]

  for {desc, app_env, toml, expected} <- @cases do
    test "#{desc} resolves to #{expected}" do
      assert_role(unquote(app_env), unquote(toml), unquote(expected))
    end
  end

  test "an unrecognised role raises rather than defaulting either way" do
    Toml.put_cache(%{"node" => %{"role" => "worker"}})

    assert_raise ArgumentError, ~r/must be "host" or "control"/, &Config.role/0
  end

  # The row's values arrive as arguments rather than being inlined in the
  # generated test body: with the literals in scope the compiler narrows them to
  # one value and reports the other clauses — and the `==` below — as dead.
  defp assert_role(app_env, toml, expected) do
    put_app_env(app_env)
    put_toml(toml)

    assert Config.role() == expected
    assert Config.host?() == (expected == :host)
    assert Config.control?() == (expected == :control)
  end

  defp put_app_env(nil), do: :ok
  defp put_app_env(role), do: Application.put_env(:hyper, Config, role: role)

  defp put_toml(nil), do: :ok
  defp put_toml(role), do: Toml.put_cache(%{"node" => %{"role" => role}})
end
