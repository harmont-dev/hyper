defmodule Redist.Sha256PropertiesTest do
  @moduledoc """
  `Sha256.file/1` folds a file through `:crypto` in 2 MiB chunks. The contract it
  must uphold for EVERY input: the streamed digest equals the one-shot
  `:crypto.hash(:sha256, _)` of the same bytes, rendered as 64 lowercase hex
  characters. The example test spot-checks a single string; these laws cover
  arbitrary content, and the explicit cases pin the two boundaries the streaming
  loop can get wrong on its own - the empty (`:eof`-first) file and the
  multi-chunk read across the 2 MiB boundary.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Redist.Sha256

  # The streaming digest must equal a hash computed in one shot over the same
  # bytes - this is the only thing `file/1` promises, and it is exactly what a
  # chunking bug (dropped/duplicated/misordered chunk) would break.
  property "streamed file digest equals the one-shot :crypto digest" do
    check all(data <- binary()) do
      with_temp_file(data, fn path ->
        assert Sha256.file(path) == oneshot(data)
      end)
    end
  end

  # The encoding half of the contract: lowercase hex, fixed 32-byte (64-char)
  # width, regardless of input.
  property "digest is always 64 lowercase hex characters" do
    check all(data <- binary()) do
      with_temp_file(data, fn path ->
        assert Sha256.file(path) =~ ~r/\A[0-9a-f]{64}\z/
      end)
    end
  end

  # `:file.read/2` returns `:eof` immediately for an empty file; the fold must
  # still finalize the (empty-input) digest rather than crash or skip.
  test "empty file hashes to the empty-input digest" do
    with_temp_file(<<>>, fn path ->
      assert Sha256.file(path) == oneshot(<<>>)
    end)
  end

  # Cross the 2 MiB chunk boundary deterministically: property inputs stay small
  # for fast shrinking, so a single large input exercises the multi-read path
  # (and the non-multiple-of-chunk-size tail).
  test "matches the one-shot digest across the 2 MiB chunk boundary" do
    data = :binary.copy(<<0xAB>>, 5 * 1024 * 1024 + 7)

    with_temp_file(data, fn path ->
      assert Sha256.file(path) == oneshot(data)
    end)
  end

  defp oneshot(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  defp with_temp_file(data, fun) do
    path = Path.join(System.tmp_dir!(), "sha256-prop-#{System.unique_integer([:positive])}.bin")
    File.write!(path, data)

    try do
      fun.(path)
    after
      File.rm(path)
    end
  end
end
