defmodule Hyper.SuidHelper.ThinDump do
  @moduledoc """
  Extract a thin device's provisioned-range map from the pool's metadata, via
  the setuid helper's `thin-dump` tool (thin-provisioning-tools). Only valid
  while the pool's metadata snapshot is reserved — see
  `Hyper.Node.Img.ThinPool.mappings/1`, the sole intended caller.
  """

  use OpenTelemetryDecorator

  alias Hyper.SuidHelper

  @type err :: SuidHelper.err()

  @doc """
  Provisioned `[begin, length]` ranges of thin device `dev_id` in pool blocks,
  plus the pool block size in 512-byte sectors — the shape
  `Hyper.SuidHelper.Blockcopy.copy/3` consumes verbatim as `ranges_spec`.
  """
  @spec mappings(Path.t(), non_neg_integer()) ::
          {:ok, %{block_sectors: pos_integer(), ranges: [[non_neg_integer()]]}}
          | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.ThinDump.mappings", include: [:meta_dev, :dev_id])
  def mappings(meta_dev, dev_id) do
    argv = ["thin-dump", "--meta", meta_dev, "--dev-id", Integer.to_string(dev_id)]

    case SuidHelper.exec(argv) do
      {:ok, %{"block_sectors" => block_sectors, "ranges" => ranges}} ->
        {:ok, %{block_sectors: block_sectors, ranges: ranges}}

      {:error, _} = err ->
        err
    end
  end
end
