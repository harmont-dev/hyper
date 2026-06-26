defmodule Hyper.Cfg.Budget do
  @moduledoc """
  This node's resource budget. Each field reads from `config.exs`
  (`config :hyper, Hyper.Cfg.Budget, ...`), then the `[budget]` table in
  `/etc/hyper/config.toml`, then its default. `Unit.*` quantities may be given
  as Elixir terms in `config.exs` or as strings (`"4GiB"`, `"1GiBps"`) in TOML.
  """

  import Hyper.Cfg, only: [fetch_cfg: 1]

  @type t :: %__MODULE__{
          mem_max: Unit.Information.t(),
          disk_max: Unit.Information.t(),
          cpu_max_load: float(),
          cpu_max_cap: float() | nil,
          disk_bw_cap: Unit.Bandwidth.t(),
          disk_bw_max_load: float(),
          net_bw_cap: Unit.Bandwidth.t(),
          net_bw_max_load: float()
        }
  defstruct [
    :mem_max,
    :disk_max,
    :cpu_max_load,
    :cpu_max_cap,
    :disk_bw_cap,
    :disk_bw_max_load,
    :net_bw_cap,
    :net_bw_max_load
  ]

  @spec load :: {:ok, t()} | {:error, term()}
  def load do
    with {:ok, mem_max} <- information(:mem_max, "budget.mem_max"),
         {:ok, disk_max} <- information(:disk_max, "budget.disk_max"),
         {:ok, cpu_max_load} <- number(:cpu_max_load, "budget.cpu_max_load"),
         {:ok, disk_bw_cap} <- bandwidth(:disk_bw_cap, "budget.disk_bw_cap"),
         {:ok, disk_bw_max_load} <- number(:disk_bw_max_load, "budget.disk_bw_max_load"),
         {:ok, net_bw_cap} <- bandwidth(:net_bw_cap, "budget.net_bw_cap"),
         {:ok, net_bw_max_load} <- number(:net_bw_max_load, "budget.net_bw_max_load") do
      config = %__MODULE__{
        mem_max: mem_max,
        disk_max: disk_max,
        cpu_max_load: cpu_max_load,
        cpu_max_cap: optional_number(:cpu_max_cap, "budget.cpu_max_cap"),
        disk_bw_cap: disk_bw_cap,
        disk_bw_max_load: disk_bw_max_load,
        net_bw_cap: net_bw_cap,
        net_bw_max_load: net_bw_max_load
      }

      :persistent_term.put(__MODULE__, config)
      {:ok, config}
    end
  end

  @spec get :: t()
  def get, do: :persistent_term.get(__MODULE__)

  @spec information(atom(), String.t()) :: {:ok, Unit.Information.t()} | {:error, term()}
  defp information(key, toml) do
    with {:ok, v} <- required(key, toml) do
      coerce(v, &Unit.Information.parse/1, Unit.Information, key)
    end
  end

  @spec bandwidth(atom(), String.t()) :: {:ok, Unit.Bandwidth.t()} | {:error, term()}
  defp bandwidth(key, toml) do
    with {:ok, v} <- required(key, toml) do
      coerce(v, &Unit.Bandwidth.parse/1, Unit.Bandwidth, key)
    end
  end

  @spec number(atom(), String.t()) :: {:ok, number()} | {:error, term()}
  defp number(key, toml) do
    case required(key, toml) do
      {:ok, n} when is_number(n) -> {:ok, n}
      {:ok, other} -> {:error, {:not_a_number, key, other}}
      {:error, _} = e -> e
    end
  end

  @spec optional_number(atom(), String.t()) :: number() | nil
  defp optional_number(key, toml) do
    case fetch_cfg(runtime: {__MODULE__, key}, toml: toml) do
      {:ok, n} when is_number(n) -> n
      _ -> nil
    end
  end

  @spec required(atom(), String.t()) :: {:ok, term()} | {:error, term()}
  defp required(key, toml) do
    case fetch_cfg(runtime: {__MODULE__, key}, toml: toml) do
      {:ok, v} -> {:ok, v}
      :error -> {:error, {:missing, key}}
    end
  end

  # Accept an already-typed struct (from config.exs) or a string to parse (from TOML).
  @spec coerce(term(), (String.t() -> {:ok, struct()} | {:error, term()}), module(), atom()) ::
          {:ok, struct()} | {:error, term()}
  defp coerce(%mod{} = v, _parse, mod, _key), do: {:ok, v}

  defp coerce(s, parse, _mod, key) when is_binary(s) do
    case parse.(s) do
      {:ok, v} -> {:ok, v}
      {:error, _} -> {:error, {:bad_value, key, s}}
    end
  end

  defp coerce(other, _parse, _mod, key), do: {:error, {:bad_value, key, other}}
end
