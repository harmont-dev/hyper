defmodule Hyper.Node.FireVMM.GuestAgentTest do
  use ExUnit.Case, async: true

  alias Hyper.Node.FireVMM.GuestAgent

  test "path/1 is a per-arch absolute path under the install dir" do
    x = GuestAgent.path(:x86_64)
    a = GuestAgent.path(:aarch64)
    assert Path.type(x) == :absolute
    assert x != a
    assert String.contains?(x, "x86_64")
    assert String.contains?(a, "aarch64")
  end

  test "check/2 classifies the binary state: missing, not executable, ok" do
    tmp = Path.join(System.tmp_dir!(), "guest-agent-check-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    # {row label, setup returning the path, expected}
    rows = [
      {"missing file", fn -> Path.join(tmp, "absent") end, {:error, {:not_installed, :x86_64}}},
      {"present but not executable",
       fn ->
         p = Path.join(tmp, "noexec")
         File.write!(p, "bin")
         File.chmod!(p, 0o644)
         p
       end, {:error, {:not_executable, :x86_64}}},
      {"present and executable",
       fn ->
         p = Path.join(tmp, "ok")
         File.write!(p, "bin")
         File.chmod!(p, 0o755)
         p
       end, :ok}
    ]

    for {label, setup, expected} <- rows do
      assert GuestAgent.check(setup.(), :x86_64) == expected, label
    end
  end
end
