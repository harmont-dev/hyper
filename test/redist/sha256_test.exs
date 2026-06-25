defmodule Redist.Sha256Test do
  use ExUnit.Case, async: true

  alias Redist.Sha256

  test "file/1 returns the lowercase-hex streaming SHA-256 of the file" do
    dir = System.tmp_dir!()
    path = Path.join(dir, "sha256-#{System.unique_integer([:positive])}.bin")
    File.write!(path, "hyper")
    on_exit(fn -> File.rm(path) end)

    expected = :crypto.hash(:sha256, "hyper") |> Base.encode16(case: :lower)
    assert Sha256.file(path) == expected
  end
end
