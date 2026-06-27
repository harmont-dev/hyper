defmodule Hyper.Cfg do
  @moduledoc """
  The one place every Hyper configuration value is read.

  Configuration is layered, highest priority first:

    1. `/etc/hyper/config.exs` — runtime app env, unprivileged node only. The
       right place for secrets loaded at boot.
    2. `/etc/hyper/config.toml` — static, **shared with `hyper-suidhelper`**.
       Anything that influences a root process lives here so the two sides can
       never drift.
    3. Compile-time `config/config.exs` — performance fine-tuning.
    4. Built-in defaults.

  Each value names *which* of these layers it may be read from. Privileged tool
  paths and the helper-shared `[jails]` table are `config.toml`-only, so the
  unprivileged `config.exs` can never override a root-impacting path.

  Read values through the focused submodules — `Hyper.Cfg.Tools`,
  `Hyper.Cfg.Dirs`, `Hyper.Cfg.Jails`, `Hyper.Cfg.Budget`, ... — never reach for
  `Application.get_env` or `Hyper.Cfg.Toml` directly.
  """

  defmodule MissingError do
    @moduledoc "Raised when a required config value is absent from every permitted source."
    defexception [:message]
  end

  @type source ::
          {:exs, {keyword(), atom()}}
          | {:runtime, atom() | {module(), atom()}}
          | {:toml, String.t()}
          | {:default, term()}

  @doc false
  @spec fetch_cfg([source]) :: {:ok, term()} | :error
  def fetch_cfg(sources) when is_list(sources), do: resolve(sources)

  @doc false
  @spec get_cfg([source]) :: term()
  def get_cfg(sources) when is_list(sources) do
    case fetch_cfg(sources) do
      {:ok, value} ->
        value

      :error ->
        raise MissingError,
          message:
            "required config value is not set in any permitted source: " <>
              inspect(Keyword.delete(sources, :default))
    end
  end

  @spec resolve([source]) :: {:ok, term()} | :error
  defp resolve([]), do: :error

  defp resolve([source | rest]) do
    case from(source) do
      {:ok, value} -> {:ok, value}
      :error -> resolve(rest)
    end
  end

  @spec from(source) :: {:ok, term()} | :error
  defp from({:default, value}), do: {:ok, value}
  defp from({:toml, path}), do: Hyper.Cfg.Toml.fetch(path)

  # An explicit keyword list, used when config.exs is read by hand during
  # `config/runtime.exs` boot (before it reaches app env) — see `Hyper.Cfg.Otel`.
  defp from({:exs, {kw, key}}) when is_list(kw), do: Keyword.fetch(kw, key)

  defp from({:runtime, {mod, key}}) do
    case Application.get_env(:hyper, mod) do
      kw when is_list(kw) -> Keyword.fetch(kw, key)
      _ -> :error
    end
  end

  defp from({:runtime, key}) when is_atom(key) do
    case Application.get_env(:hyper, key) do
      nil -> :error
      value -> {:ok, value}
    end
  end
end
