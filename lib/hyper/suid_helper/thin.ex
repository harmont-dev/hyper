defmodule Hyper.SuidHelper.Thin do
  @moduledoc false

  use OpenTelemetryDecorator

  alias Hyper.SuidHelper

  @type err :: SuidHelper.err()

  @spec create_pool(String.t(), Path.t(), Path.t(), pos_integer(), non_neg_integer()) ::
          {:ok, Path.t(), Path.t()} | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Thin.create_pool", include: [:name])
  def create_pool(name, meta_file, data_file, block_sectors, low_water) do
    request = %{
      op: "thin_pool_create",
      name: name,
      metadata: meta_file,
      data: data_file,
      block_sectors: block_sectors,
      low_water: low_water
    }

    case SuidHelper.exec(request) do
      {:ok, %{"result" => "created", "device" => dev, "loops" => %{"metadata" => meta_loop}}} ->
        {:ok, dev, meta_loop}

      {:error, _} = err ->
        err
    end
  end

  @spec create_volume(String.t(), non_neg_integer(), String.t(), Path.t(), String.t() | nil) ::
          {:ok, Path.t()} | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Thin.create_volume", include: [:name, :thin_id, :parent])
  def create_volume(pool, thin_id, name, origin, parent) do
    %{op: "thin_volume_create", pool: pool, thin_id: thin_id, name: name, origin: origin}
    |> put_parent(parent)
    |> created()
  end

  @spec put_parent(map(), String.t() | nil) :: map()
  defp put_parent(request, nil), do: request
  defp put_parent(request, parent), do: Map.put(request, :parent, parent)

  @spec destroy(String.t(), String.t()) :: :ok | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Thin.destroy", include: [:name])
  def destroy(pool, name) do
    case SuidHelper.exec(%{op: "thin_destroy", pool: pool, name: name}) do
      {:ok, %{"result" => "destroyed"}} -> :ok
      {:error, _} = err -> err
    end
  end

  @spec created(map()) :: {:ok, Path.t()} | {:error, err()}
  defp created(request) do
    case SuidHelper.exec(request) do
      {:ok, %{"result" => "created", "device" => device}} -> {:ok, device}
      {:error, _} = err -> err
    end
  end
end
