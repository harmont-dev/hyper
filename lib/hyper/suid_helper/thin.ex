defmodule Hyper.SuidHelper.Thin do
  @moduledoc false

  use OpenTelemetryDecorator

  alias Hyper.SuidHelper

  @type err :: SuidHelper.err()

  @spec create(String.t(), non_neg_integer(), String.t(), Path.t()) ::
          {:ok, Path.t()} | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Thin.create", include: [:name, :thin_id])
  def create(pool, thin_id, name, origin) do
    created(%{op: "thin_create", pool: pool, thin_id: thin_id, name: name, origin: origin})
  end

  @spec snapshot(String.t(), String.t(), non_neg_integer(), String.t(), Path.t()) ::
          {:ok, Path.t()} | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Thin.snapshot", include: [:parent, :name, :thin_id])
  def snapshot(pool, parent, thin_id, name, origin) do
    created(%{
      op: "thin_snapshot",
      pool: pool,
      parent: parent,
      thin_id: thin_id,
      name: name,
      origin: origin
    })
  end

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
