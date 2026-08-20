defmodule Hyper.Cfg.Role do
  @moduledoc """
  This node's role in a Hyper cluster.

    * `:worker` — a full VM-running node. Firecracker, KVM and the setuid helper
      (`hyper-suidhelper`) are available, and it starts `Hyper.Node`, so VMs
      scheduled onto it actually boot here.
    * `:client` — a control-plane-only node. It runs no Firecracker/KVM and has
      no `hyper-suidhelper`; instead it schedules work onto workers and runs the
      autoscaler (`Hyper.Autoscale`), which provisions more workers on demand.

  Read from `config.exs` (`config :hyper, Hyper.Cfg.Role, role: :client`) first,
  then the `role` TOML key, defaulting to `:worker`. The value may be given as an
  atom or a string; anything other than `worker`/`client` raises `ArgumentError`
  so a typo fails loudly at boot rather than silently degrading the node.
  """

  import Hyper.Cfg, only: [get_cfg: 1]

  @type t :: :worker | :client

  @doc "This node's configured role."
  @spec get() :: t()
  def get do
    normalize(get_cfg(runtime: {__MODULE__, :role}, toml: "role", default: :worker))
  end

  @doc "True on a full VM-running (`:worker`) node."
  @spec worker?() :: boolean()
  def worker?, do: get() == :worker

  @doc "True on a control-plane-only (`:client`) node."
  @spec client?() :: boolean()
  def client?, do: get() == :client

  @spec normalize(term()) :: t()
  defp normalize(role) when role in [:worker, :client], do: role
  defp normalize("worker"), do: :worker
  defp normalize("client"), do: :client

  defp normalize(other) do
    raise ArgumentError,
          "invalid Hyper node role #{inspect(other)}; expected :worker or :client"
  end
end
