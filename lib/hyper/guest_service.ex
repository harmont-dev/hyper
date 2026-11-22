defmodule Hyper.GuestService do
  @moduledoc false

  alias Hyper.GuestService.Header
  alias Unit.Time

  @reserved_prefix "hyper-"

  @enforce_keys [:handler]
  @derive {Inspect, except: [:handler]}
  defstruct [:name, :handler, max_connections: 16, idle_timeout: Time.s(300)]

  @type name :: String.t()
  @type t :: %__MODULE__{
          name: name() | nil,
          handler: {module(), term()},
          max_connections: pos_integer(),
          idle_timeout: Time.t()
        }

  @type resolve_error ::
          {:guest_service_handler_not_loaded, module()}
          | {:invalid_guest_service, term(),
             :handler | :name | :reserved_name | :max_connections | :idle_timeout}
          | {:duplicate_guest_service, name()}

  @spec resolve_all([t()]) :: {:ok, [t()]} | {:error, resolve_error()}
  def resolve_all(services) do
    with {:ok, resolved} <- resolve_each(services),
         :ok <- unique(resolved, MapSet.new()) do
      {:ok, resolved}
    end
  end

  @spec ensure_loaded([t()]) :: :ok | {:error, {:guest_service_handler_not_loaded, module()}}
  def ensure_loaded([]), do: :ok

  def ensure_loaded([%__MODULE__{handler: {mod, _arg}} | rest]) do
    if handler?(mod),
      do: ensure_loaded(rest),
      else: {:error, {:guest_service_handler_not_loaded, mod}}
  end

  defp resolve_each([]), do: {:ok, []}

  defp resolve_each([service | rest]) do
    with {:ok, resolved} <- resolve(service),
         {:ok, others} <- resolve_each(rest) do
      {:ok, [resolved | others]}
    end
  end

  defp resolve(%__MODULE__{handler: {mod, _arg}} = service) when is_atom(mod) do
    with :ok <- ensure_loaded([service]),
         name = service.name || mod.name(),
         :ok <- check(service, mod, name) do
      {:ok, %{service | name: name}}
    end
  end

  defp resolve(%__MODULE__{handler: handler}),
    do: {:error, {:invalid_guest_service, handler, :handler}}

  defp check(service, mod, name) do
    cond do
      not Header.valid_name?(name) ->
        {:error, {:invalid_guest_service, mod, :name}}

      String.starts_with?(name, @reserved_prefix) ->
        {:error, {:invalid_guest_service, mod, :reserved_name}}

      not (is_integer(service.max_connections) and service.max_connections > 0) ->
        {:error, {:invalid_guest_service, mod, :max_connections}}

      Time.as_ms(service.idle_timeout) <= 0 ->
        {:error, {:invalid_guest_service, mod, :idle_timeout}}

      true ->
        :ok
    end
  end

  defp unique([], _seen), do: :ok

  defp unique([%__MODULE__{name: name} | rest], seen) do
    if MapSet.member?(seen, name),
      do: {:error, {:duplicate_guest_service, name}},
      else: unique(rest, MapSet.put(seen, name))
  end

  defp handler?(mod) do
    Code.ensure_loaded?(mod) and function_exported?(mod, :name, 0) and
      function_exported?(mod, :init, 2) and function_exported?(mod, :handle_data, 2)
  end
end
