defmodule Hyper.Cfg.Vmlinux do
  @moduledoc """
  Per-architecture guest-kernel image paths, set by the operator in
  `config :hyper, vmlinux: %{arch => path}`. Node-only; no helper counterpart.
  """

  import Hyper.Cfg, only: [get_cfg: 1]

  @doc "Operator-configured `%{arch => path}` kernel map, default `%{}`."
  # Runtime read, not compile_env: an unset map would inline a literal `%{}`,
  # which the type checker proves makes every Map.fetch/2 on it return :error.
  @spec images :: %{optional(Sys.Arch.t()) => Path.t()}
  def images, do: get_cfg(runtime: :vmlinux, default: %{})
end
