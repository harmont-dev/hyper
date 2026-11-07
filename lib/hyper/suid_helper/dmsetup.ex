defmodule Hyper.SuidHelper.Dmsetup do
  @moduledoc "device-mapper operations (snapshot / thin), via the setuid helper's `dmsetup` tool."

  use OpenTelemetryDecorator

  alias Hyper.SuidHelper

  @type err :: SuidHelper.err()

  @doc """
  Create a read-only dm-snapshot device named `name`, layering `cow_dev`
  (exception store) over `origin_dev`. `sectors` is the logical size in 512-byte
  sectors. Returns the `/dev/mapper/<name>` path.
  """
  @spec create_snapshot(String.t(), Path.t(), Path.t()) :: {:ok, Path.t()} | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Dmsetup.create_snapshot", include: [:name])
  def create_snapshot(name, origin, cow_file) do
    with {:ok, dev, _loops} <- create(snapshot(name, origin, cow_file)),
         do: {:ok, dev}
  end

  @spec create_linear(String.t(), Path.t()) :: {:ok, Path.t()} | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Dmsetup.create_linear", include: [:name])
  def create_linear(name, origin) do
    request = %{op: "dm_linear", name: name, origin: origin}
    with {:ok, dev, _loops} <- create(request), do: {:ok, dev}
  end

  @doc """
  Create a dm-thin pool `name` backed by `meta_dev` (metadata loop) and
  `data_dev` (data loop). `sectors` is the data device size; `block_sectors` the
  allocation block size; `low_water` the low-water mark in blocks. Returns the
  `/dev/mapper/<name>` path.
  """
  @spec create_thin_pool(
          String.t(),
          Path.t(),
          Path.t(),
          pos_integer(),
          non_neg_integer()
        ) :: {:ok, Path.t(), Path.t()} | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Dmsetup.create_thin_pool", include: [:name])
  def create_thin_pool(name, meta_file, data_file, block_sectors, low_water) do
    request = %{
      op: "dm_thin_pool",
      name: name,
      metadata: meta_file,
      data: data_file,
      block_sectors: block_sectors,
      low_water: low_water
    }

    with {:ok, dev, %{"metadata" => meta_loop}} <- create(request),
         do: {:ok, dev, meta_loop}
  end

  @doc "Remove the dm device `name`."
  @spec remove(String.t()) :: :ok | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Dmsetup.remove", include: [:name])
  def remove(name) do
    case SuidHelper.exec(%{op: "dm_remove", name: name, retry: true}) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @spec snapshot(String.t(), Path.t(), Path.t()) :: map()
  defp snapshot(name, origin, cow_file) do
    %{
      op: "dm_snapshot",
      name: name,
      origin: origin,
      cow: cow_file,
      chunk_sectors: Hyper.Cfg.Img.chunk_sectors()
    }
  end

  @spec create(map()) :: {:ok, Path.t(), %{String.t() => Path.t()}} | {:error, err()}
  defp create(request) do
    case SuidHelper.exec(request) do
      {:ok, %{"device" => dev, "loops" => loops}} -> {:ok, dev, loops}
      {:error, _} = err -> err
    end
  end
end
