defmodule Hyper.Node.Img.WritableTest do
  use ExUnit.Case, async: true
  alias Hyper.Node.Img.Writable

  test "dm_name/1 is a safe hyper- name derived from vm id" do
    name = Writable.dm_name("vm/ABC.1")
    assert String.starts_with?(name, "hyper-rw-")
    assert name =~ ~r/^[A-Za-z0-9._-]+$/
  end
end
