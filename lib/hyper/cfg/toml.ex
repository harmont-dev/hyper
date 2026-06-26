defmodule Hyper.Cfg.Toml do
  @moduledoc false
  # Internal: the raw read+cache of /etc/hyper/config.toml, the single source of
  # truth shared with the setuid helper (native/suidhelper). Read once on first
  # access and cached in :persistent_term; an absent file (local dev / CI) yields
  # an empty map so the built-in defaults in Hyper.Cfg.* take over and the node
  # still agrees with the helper. Only Hyper.Cfg.* may call this module.

  @config_path "/etc/hyper/config.toml"

  @doc "Fetch a dotted key path (e.g. `\"tools.firecracker\"`) from the cached config."
  @spec fetch(String.t()) :: {:ok, term()} | :error
  def fetch(path), do: fetch_in(config(), path)

  @doc "Pure dotted-path lookup into an already-decoded map (exposed for tests)."
  @spec fetch_in(map(), String.t()) :: {:ok, term()} | :error
  def fetch_in(map, path) do
    Enum.reduce_while(String.split(path, "."), {:ok, map}, fn seg, {:ok, acc} ->
      case acc do
        %{^seg => v} -> {:cont, {:ok, v}}
        _ -> {:halt, :error}
      end
    end)
  end

  @doc "Path to the shared config file."
  @spec path :: Path.t()
  def path, do: @config_path

  @doc "Drop the cache so the next read re-parses the file (test hook)."
  @spec reload :: map()
  def reload do
    :persistent_term.erase({__MODULE__, :config})
    config()
  end

  @doc "Seed the cache with a decoded map, bypassing the file (test hook)."
  @spec put_cache(map()) :: :ok
  def put_cache(cfg), do: :persistent_term.put({__MODULE__, :config}, cfg)

  @spec config :: map()
  defp config do
    case :persistent_term.get({__MODULE__, :config}, nil) do
      nil ->
        cfg = load()
        :persistent_term.put({__MODULE__, :config}, cfg)
        cfg

      cfg ->
        cfg
    end
  end

  @spec load :: map()
  defp load do
    case File.read(@config_path) do
      {:ok, body} -> Toml.decode!(body)
      {:error, _} -> %{}
    end
  end
end
