defmodule Hyper.SuidHelper.Img do
  @moduledoc false

  use OpenTelemetryDecorator

  alias Hyper.SuidHelper

  @type err :: SuidHelper.err()

  @spec activate(String.t(), Path.t(), [Path.t()]) ::
          {:ok, %{blk_path: Path.t(), dm_names: [String.t()]}} | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Img.activate", include: [:name])
  def activate(name, base, deltas) do
    request = %{
      op: "img_activate",
      name: name,
      base: base,
      deltas: deltas,
      chunk_sectors: Hyper.Cfg.Img.chunk_sectors()
    }

    case SuidHelper.exec(request) do
      {:ok, %{"result" => "activated", "device" => device, "names" => names}} ->
        {:ok, %{blk_path: device, dm_names: names}}

      {:error, _} = err ->
        err
    end
  end
end
