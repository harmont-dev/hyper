defmodule Hyper.Img.CreateFailureTest do
  @moduledoc """
  `create/2` refuses bad input before touching the store or DB, and never
  succeeds on a file it could not read. Kills a mutation that would let a
  missing/unreadable source through, or crash instead of returning an error
  tuple the caller can handle.
  """
  use ExUnit.Case, async: true

  alias Hyper.Img

  test "a missing source is refused with the underlying posix error" do
    assert {:error, :enoent} = Img.create("/no/such/path.img")
  end

  test "a source that stats but cannot be hashed becomes {:hash_failed, _}" do
    # A directory: File.stat/1 succeeds, but the streaming sha256 raises on open.
    assert {:error, {:hash_failed, msg}} = Img.create(System.tmp_dir!())
    assert is_binary(msg)
  end
end
