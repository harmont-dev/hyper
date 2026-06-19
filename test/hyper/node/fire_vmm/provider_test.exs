defmodule Hyper.Node.FireVMM.ProviderTest do
  use ExUnit.Case, async: true

  alias Hyper.Node.FireVMM.Provider

  test "target_arch/0 returns a supported architecture on this host" do
    assert {:ok, arch} = Provider.target_arch()
    assert arch in ["x86_64", "aarch64"]
  end

  describe "checksums" do
    setup do
      dir = Path.join(System.tmp_dir!(), "provider-sha-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "sha256_file/1 matches :crypto over the whole file", %{dir: dir} do
      path = Path.join(dir, "blob.bin")
      bytes = :binary.copy(<<0, 1, 2, 3, 4, 5, 6, 7>>, 100_000)
      File.write!(path, bytes)

      expected =
        :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

      assert Provider.sha256_file(path) == expected
    end

    test "verify_checksum/2 returns :ok on match", %{dir: dir} do
      path = Path.join(dir, "ok.bin")
      File.write!(path, "hello")
      sha = Provider.sha256_file(path)
      assert :ok = Provider.verify_checksum(path, sha)
    end

    test "verify_checksum/2 returns an error tuple on mismatch", %{dir: dir} do
      path = Path.join(dir, "bad.bin")
      File.write!(path, "hello")
      actual = Provider.sha256_file(path)

      assert {:error, {:checksum_mismatch, "deadbeef", ^actual}} =
               Provider.verify_checksum(path, "deadbeef")
    end
  end
end
