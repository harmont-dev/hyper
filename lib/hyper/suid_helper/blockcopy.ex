defmodule Hyper.SuidHelper.Blockcopy do
  @moduledoc """
  Chunked ranged copy between block devices, via the setuid helper's
  `blockcopy` tool — used to fill a fork delta layer's COW store with exactly
  the divergent chunks.
  """

  use OpenTelemetryDecorator

  alias Hyper.SuidHelper

  @type err :: SuidHelper.err()

  @doc """
  Copy exactly the block ranges in the `ranges_path` JSON file (from
  `Hyper.SuidHelper.ThinDump.mappings/2`) from `src` into `dst` at identical
  offsets, via the setuid helper's `blockcopy` tool.
  """
  @spec copy(Path.t(), Path.t(), Path.t()) ::
          {:ok, %{scanned: non_neg_integer(), written: non_neg_integer()}} | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Blockcopy.copy", include: [:src, :dst])
  def copy(src, dst, ranges_path) do
    argv = ["blockcopy", "--src", src, "--dst", dst, "--ranges", ranges_path]

    case SuidHelper.exec(argv) do
      {:ok, %{"scanned_chunks" => scanned, "written_chunks" => written}} ->
        {:ok, %{scanned: scanned, written: written}}

      {:error, _} = err ->
        err
    end
  end
end
