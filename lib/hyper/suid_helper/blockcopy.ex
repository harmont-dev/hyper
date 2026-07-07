defmodule Hyper.SuidHelper.Blockcopy do
  @moduledoc """
  Chunked diff-copy between block devices, via the setuid helper's `blockcopy`
  tool. With `:reference` set, only chunks of `src` differing from the reference
  are written into `dst` — used to fill a fork delta layer's COW store.
  """

  use OpenTelemetryDecorator

  alias Hyper.SuidHelper

  @type err :: SuidHelper.err()

  @doc "Copy `src` into `dst`; `opts[:reference]` skips chunks equal to it; `opts[:ranges]` copies only the block ranges in the given JSON file (from `ThinDump.mappings/2`)."
  @spec copy(Path.t(), Path.t(), keyword()) ::
          {:ok, %{scanned: non_neg_integer(), written: non_neg_integer()}} | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Blockcopy.copy", include: [:src, :dst])
  def copy(src, dst, opts \\ []) do
    argv =
      ["blockcopy", "--src", src, "--dst", dst] ++
        reference_args(opts[:reference]) ++ ranges_args(opts[:ranges])

    case SuidHelper.exec(argv) do
      {:ok, %{"scanned_chunks" => scanned, "written_chunks" => written}} ->
        {:ok, %{scanned: scanned, written: written}}

      {:error, _} = err ->
        err
    end
  end

  @spec reference_args(Path.t() | nil) :: [String.t()]
  defp reference_args(nil), do: []
  defp reference_args(reference), do: ["--reference", reference]

  @spec ranges_args(Path.t() | nil) :: [String.t()]
  defp ranges_args(nil), do: []
  defp ranges_args(path), do: ["--ranges", path]
end
