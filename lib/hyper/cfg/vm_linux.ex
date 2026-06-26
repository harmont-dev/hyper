defmodule Hyper.Cfg.VmLinux do
  @moduledoc """
  Per-architecture guest-kernel image paths. Operators set `amd64`/`aarch64`
  (mapped to `:x86_64`/`:aarch64`) in `config :hyper, Hyper.Cfg.VmLinux, ...` or
  the `[vmlinux]` toml table. An unset architecture is simply absent from the map.
  """

  import Hyper.Cfg, only: [fetch_cfg: 1]

  @archs %{amd64: :x86_64, aarch64: :aarch64}

  @doc "Resolved `%{arch => path}` kernel map (config.exs per key > [vmlinux] toml)."
  @spec images :: %{optional(Sys.Arch.t()) => Path.t()}
  def images do
    for {doc_key, arch} <- @archs, {:ok, path} <- [resolve(doc_key)], into: %{}, do: {arch, path}
  end

  @spec resolve(atom()) :: {:ok, Path.t()} | :error
  defp resolve(doc_key),
    do: fetch_cfg(runtime: {__MODULE__, doc_key}, toml: "vmlinux.#{doc_key}")
end
