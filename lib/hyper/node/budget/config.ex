defmodule Hyper.Node.Config.Budget do
  @type t :: %__MODULE__{
          mem_max: Unit.Information.t(),
          disk_max: Unit.Information.t()
        }
  defstruct [:mem_max, :disk_max]

  @spec load :: {:ok, t()} | {:error, term()}
  def load do
    case Application.fetch_env(:hyper, __MODULE__) do
      {:ok, env} ->
        case safe_struct(env) do
          {:ok, config} ->
            # TODO(markovejnovic): Check whether the limits are under the
            # system limits by querying Sys.
            :persistent_term.put(__MODULE__, config)
            {:ok, config}

          {:error, _} = err ->
            err
        end

      :error ->
        {:error, :config_missing}
    end
  end

  defp safe_struct(env) do
    {:ok, struct!(__MODULE__, env)}
  rescue
    e in KeyError -> {:error, {:unknown_key, e.key}}
    e in ArgumentError -> {:error, {:invalid_config, e.message}}
  end

  @spec get :: t()
  def get, do: :persistent_term.get(__MODULE__)
end
