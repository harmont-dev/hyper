defmodule Sys.Linux.KvmTest do
  use ExUnit.Case, async: true

  alias Sys.Linux.Kvm

  test "parse_nested/1 decodes both vendor formats and nothing else" do
    for {raw, expected} <- [
          {"Y\n", true},
          {"N\n", false},
          {"1\n", true},
          {"0\n", false},
          {"", :unknown},
          {"yes\n", :unknown}
        ] do
      assert Kvm.parse_nested(raw) == expected, inspect(raw)
    end
  end
end
