defmodule Mix.Tasks.Firecracker.InstallTest do
  @moduledoc """
  `mix firecracker.install` against the real pinned release.

  Laws:

    * whatever already sits at `<prefix>/firecracker` or `<prefix>/jailer` - a
      symlink or a hard link to someone else's file - is replaced, never
      written through: the file it named keeps its bytes;
    * each installed binary is a fresh regular file, mode `0755`, that runs as
      the pinned version;
    * reinstalling over a finished install succeeds and yields the same bytes.
  """
  use ExUnit.Case, async: false

  @moduletag :external
  @moduletag timeout: 300_000

  setup do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    prefix = Path.join(System.tmp_dir!(), "fc-install-#{System.unique_integer([:positive])}")
    File.mkdir_p!(prefix)

    on_exit(fn ->
      Mix.shell(previous)
      File.rm_rf!(prefix)
    end)

    {:ok, prefix: prefix}
  end

  defp install(prefix), do: Mix.Tasks.Firecracker.Install.run(["--prefix", prefix])

  defp assert_fresh_binary(path, victims) do
    stat = File.lstat!(path)
    assert stat.type == :regular
    assert Bitwise.band(stat.mode, 0o7777) == 0o755
    refute stat.inode in Enum.map(victims, &File.stat!(&1).inode)
    {out, 0} = System.cmd(path, ["--version"], stderr_to_stdout: true)
    assert out =~ "v1.16.0"
  end

  test "planted links at the install paths are replaced, never written through", %{
    prefix: prefix
  } do
    sym_victim = Path.join(prefix, "sym-victim")
    hard_victim = Path.join(prefix, "hard-victim")
    File.write!(sym_victim, "operator data")
    File.write!(hard_victim, "other data")
    File.ln_s!(sym_victim, Path.join(prefix, "firecracker"))
    File.ln!(hard_victim, Path.join(prefix, "jailer"))

    install(prefix)

    assert File.read!(sym_victim) == "operator data"
    assert File.read!(hard_victim) == "other data"
    assert_fresh_binary(Path.join(prefix, "firecracker"), [sym_victim, hard_victim])
    assert_fresh_binary(Path.join(prefix, "jailer"), [sym_victim, hard_victim])
  end

  test "reinstalling over a finished install succeeds with the same bytes", %{prefix: prefix} do
    install(prefix)
    first = for b <- ~w(firecracker jailer), do: File.read!(Path.join(prefix, b))

    install(prefix)
    second = for b <- ~w(firecracker jailer), do: File.read!(Path.join(prefix, b))

    assert :crypto.hash(:sha256, first) == :crypto.hash(:sha256, second)
    for b <- ~w(firecracker jailer), do: assert_fresh_binary(Path.join(prefix, b), [])
  end
end
