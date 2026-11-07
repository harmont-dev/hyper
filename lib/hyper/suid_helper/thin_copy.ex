defmodule Hyper.SuidHelper.ThinCopy do
  @moduledoc false

  use OpenTelemetryDecorator

  alias Hyper.SuidHelper

  @type err :: SuidHelper.err()

  @spec copy(String.t(), Path.t(), Path.t(), Path.t(), Path.t()) ::
          {:ok, %{scanned: non_neg_integer(), written: non_neg_integer()}} | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.ThinCopy.copy", include: [:src, :cow])
  def copy(pool, meta_dev, src, origin, cow) do
    request = %{
      op: "thin_copy",
      pool: pool,
      meta: meta_dev,
      src: src,
      origin: origin,
      cow: cow,
      chunk_sectors: Hyper.Cfg.Img.chunk_sectors()
    }

    case SuidHelper.exec(request) do
      {:ok, %{"scanned_chunks" => scanned, "written_chunks" => written}} ->
        {:ok, %{scanned: scanned, written: written}}

      {:error, _} = err ->
        err
    end
  end
end
