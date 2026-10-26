defmodule Hyper.Cfg.Security do
  @moduledoc """
  Host security policy from `config.exs` (`config :hyper, Hyper.Cfg.Security,
  ...`) or the `[security]` table.
  """

  import Hyper.Cfg, only: [get_cfg: 1]

  @doc """
  Boot even when `Hyper.Node.KernelGuard` finds the host kernel exposed to a
  known guest-escape advisory. Waives every advisory, present and future.
  `[security] allow_vulnerable_kernel`, default `false`.
  """
  @spec allow_vulnerable_kernel?() :: boolean()
  def allow_vulnerable_kernel? do
    case get_cfg(
           runtime: {__MODULE__, :allow_vulnerable_kernel},
           toml: "security.allow_vulnerable_kernel",
           default: false
         ) do
      v when is_boolean(v) ->
        v

      other ->
        raise ArgumentError,
              "security.allow_vulnerable_kernel must be a boolean, got: #{inspect(other)}"
    end
  end
end
