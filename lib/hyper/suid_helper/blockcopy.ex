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
  Copy exactly the provisioned block ranges in `ranges_spec` (the map
  `Hyper.Node.Img.ThinPool.mappings/1` returns) from `src` into `dst` at
  identical offsets, via the setuid helper's `blockcopy` tool.

  The range list rides to the helper as a temp file — it can be thousands of
  entries, far past argv limits — written and cleaned up here; the helper
  validates it pre-privilege.
  """
  @spec copy(Path.t(), Path.t(), %{
          block_sectors: pos_integer(),
          ranges: [[non_neg_integer()]]
        }) ::
          {:ok, %{scanned: non_neg_integer(), written: non_neg_integer()}}
          | {:error, err() | File.posix()}
  @decorate with_span("Hyper.SuidHelper.Blockcopy.copy", include: [:src, :dst])
  def copy(src, dst, %{block_sectors: _, ranges: _} = ranges_spec) do
    Sys.Tmp.with_tempdir("blockcopy-ranges", fn dir ->
      path = Path.join(dir, "ranges.json")

      with :ok <- File.write(path, Jason.encode!(ranges_spec)) do
        run(src, dst, path)
      end
    end)
  end

  @spec run(Path.t(), Path.t(), Path.t()) ::
          {:ok, %{scanned: non_neg_integer(), written: non_neg_integer()}} | {:error, err()}
  defp run(src, dst, ranges_path) do
    argv = ["blockcopy", "--src", src, "--dst", dst, "--ranges", ranges_path]

    case SuidHelper.exec(argv) do
      {:ok, %{"scanned_chunks" => scanned, "written_chunks" => written}} ->
        {:ok, %{scanned: scanned, written: written}}

      {:error, _} = err ->
        err
    end
  end
end
