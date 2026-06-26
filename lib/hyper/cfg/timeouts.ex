defmodule Hyper.Cfg.Timeouts do
  @moduledoc """
  Teardown and RPC timeouts. The idle grace is how long a read-only image
  (`:img`), a layer mount (`:layer`), or a mutable layer (`:mutable`) lingers
  with no users before it is torn down; `fire_call_ms/0` caps a single
  Firecracker API call. Override via `config :hyper, Hyper.Cfg.Timeouts, ...`.
  """

  import Hyper.Cfg, only: [get_cfg: 1]

  @type scope :: :img | :layer | :mutable

  @doc "Idle grace before teardown for `scope`, in milliseconds (default 30s)."
  @spec idle_ms(scope()) :: pos_integer()
  def idle_ms(scope) when scope in [:img, :layer, :mutable] do
    case get_cfg(runtime: {__MODULE__, :idle_ms}, default: []) do
      kw when is_list(kw) -> Keyword.get(kw, scope, :timer.seconds(30))
      _ -> :timer.seconds(30)
    end
  end

  @doc "Per-call Firecracker API timeout, in milliseconds (default 35s)."
  @spec fire_call_ms :: pos_integer()
  def fire_call_ms, do: get_cfg(runtime: {__MODULE__, :fire_call_ms}, default: 35_000)
end
