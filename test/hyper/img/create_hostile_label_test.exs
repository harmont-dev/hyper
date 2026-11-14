defmodule Hyper.Img.CreateHostileLabelTest do
  @moduledoc """
  `Hyper.Img.create/2` under a label chosen by a LoadImage caller: v1 forwards
  `LoadImageRequest.label` verbatim (`Hyper.Grpc.Codec`), and the only check on
  the way is the wire's UTF-8 validation — a NUL byte passes it, but Postgres
  `text` cannot store it.

  Law: a label the image DB refuses yields `{:error, _}`, not a raise, and
  leaves the store as it was — no `layer_<id>.img` without a `blobs` row.
  `Hyper.Img.Db.Gc` only prunes rows whose file is gone, never files without a
  row, so such an orphan is never reclaimed: one per hostile LoadImage of a
  fresh image, each the size of the image.
  """
  use ExUnit.Case, async: false

  alias Hyper.Cfg.Dirs
  alias Hyper.Img

  @moduletag :external
  @moduletag :capture_log

  defp consumable!(bytes) do
    path = Path.join(System.tmp_dir!(), "hyper-label-#{System.unique_integer([:positive])}.img")
    File.write!(path, bytes)
    path
  end

  test "a label the DB refuses is an error that leaves no orphaned layer file" do
    for label <- ["\0", "base\0", "a\0b"] do
      bytes = :crypto.strong_rand_bytes(4096)
      id = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
      layer = Path.join(Dirs.layer_dir(), "layer_#{id}.img")
      on_exit(fn -> File.rm(layer) end)

      result =
        try do
          Img.create(consumable!(bytes), label: label)
        rescue
          e -> {:raised, e.__struct__}
        end

      left_orphan = File.exists?(layer)

      assert match?({:error, _}, result) and not left_orphan,
             "label #{inspect(label)}: #{inspect(result)}, orphaned layer file left: #{left_orphan}"
    end
  end
end
