defmodule Hyper.SuidHelper.ForkDelta do
  @moduledoc false

  use OpenTelemetryDecorator

  alias Hyper.SuidHelper

  @type err :: SuidHelper.err()

  @spec run(String.t(), Path.t(), String.t(), non_neg_integer(), Path.t(), Path.t()) ::
          {:ok, %{scanned: non_neg_integer(), written: non_neg_integer()}} | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.ForkDelta.run", include: [:parent, :cow])
  def run(pool, meta_dev, parent, scratch_id, origin, cow) do
    request = %{
      op: "thin_fork_delta",
      pool: pool,
      meta: meta_dev,
      parent: parent,
      scratch_id: scratch_id,
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
