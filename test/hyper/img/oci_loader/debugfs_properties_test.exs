defmodule Hyper.Img.OciLoader.DebugfsPropertiesTest do
  @moduledoc """
  Laws of the ownership script `Debugfs.script/1` renders for image-controlled
  paths:

    * injection-free: parsed the way debugfs parses a command line (e2fsprogs
      `ss_parse`: whitespace splits, `"` quotes, `""` is a literal quote), every
      line is exactly one `sif`/`ea_rm` command naming the fixup's path verbatim,
      and fits in one debugfs read buffer, so no path can add a token, a
      command or a `!` shell escape;
    * refusal: a path debugfs cannot carry on one line (containing `\\n` or
      `\\r`, or too long) is always refused with `{:bad_image, _}`;
    * applied to a real ext4, the script sets exactly the requested owner and
      mode, and a command debugfs rejects fails the apply.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise

  alias Hyper.Img.OciLoader.Debugfs

  @moduletag :tmp_dir

  @debugfs_line_buffer 8192

  defp path do
    StreamData.one_of([
      StreamData.binary(max_length: 40),
      StreamData.string(Enum.concat([[?", ?\s, ?\t, ?!, ?a, ?\\, ?<, ?>], [?\n, ?\r]]),
        max_length: 20
      ),
      StreamData.map(StreamData.integer(1900..2100), &String.duplicate("\"", &1))
    ])
    |> StreamData.map(&("/" <> String.replace(&1, <<0>>, "")))
  end

  defp fixup do
    StreamData.fixed_map(%{
      path: path(),
      uid: StreamData.integer(0..0xFFFFFFFE),
      gid: StreamData.integer(0..0xFFFFFFFE),
      mode: StreamData.one_of([StreamData.constant(nil), StreamData.integer(0..0o177777)]),
      drop_xattr: StreamData.boolean()
    })
  end

  defp ss_parse(line), do: ss_parse(line, :ws, nil, [])

  defp ss_parse(<<>>, :quoted, _tok, _acc), do: :unbalanced
  defp ss_parse(<<>>, _mode, nil, acc), do: Enum.reverse(acc)
  defp ss_parse(<<>>, _mode, tok, acc), do: Enum.reverse([tok | acc])

  defp ss_parse(<<c, rest::binary>>, :ws, nil, acc) when c in [?\s, ?\t],
    do: ss_parse(rest, :ws, nil, acc)

  defp ss_parse(<<?", rest::binary>>, :ws, nil, acc), do: ss_parse(rest, :quoted, "", acc)
  defp ss_parse(<<c, rest::binary>>, :ws, nil, acc), do: ss_parse(rest, :token, <<c>>, acc)

  defp ss_parse(<<c, rest::binary>>, :token, tok, acc) when c in [?\s, ?\t],
    do: ss_parse(rest, :ws, nil, [tok | acc])

  defp ss_parse(<<?", rest::binary>>, :token, tok, acc), do: ss_parse(rest, :quoted, tok, acc)

  defp ss_parse(<<c, rest::binary>>, :token, tok, acc),
    do: ss_parse(rest, :token, tok <> <<c>>, acc)

  defp ss_parse(<<?", ?", rest::binary>>, :quoted, tok, acc),
    do: ss_parse(rest, :quoted, tok <> "\"", acc)

  defp ss_parse(<<?", rest::binary>>, :quoted, tok, acc), do: ss_parse(rest, :token, tok, acc)

  defp ss_parse(<<c, rest::binary>>, :quoted, tok, acc),
    do: ss_parse(rest, :quoted, tok <> <<c>>, acc)

  defp expected_commands(%{path: p} = f) do
    [
      ["sif", p, "uid", Integer.to_string(f.uid)],
      ["sif", p, "gid", Integer.to_string(f.gid)],
      f.mode && ["sif", p, "mode", "0" <> Integer.to_string(f.mode, 8)],
      f.drop_xattr && ["ea_rm", p, "user.rootlesscontainers"]
    ]
    |> Enum.filter(& &1)
  end

  property "every line is one command over the verbatim path, or the path is refused" do
    check all(fixups <- StreamData.list_of(fixup(), max_length: 4)) do
      case Debugfs.script(fixups) do
        {:ok, script} ->
          lines = script |> IO.iodata_to_binary() |> String.split("\n", trim: true)
          assert Enum.all?(lines, &(byte_size(&1) + 1 < @debugfs_line_buffer))
          assert Enum.map(lines, &ss_parse/1) == Enum.flat_map(fixups, &expected_commands/1)

        {:error, {:bad_image, {_why, refused}}} ->
          assert refused in Enum.map(fixups, & &1.path)
          assert String.contains?(refused, ["\n", "\r"]) or byte_size(refused) >= 1900
      end
    end
  end

  property "a path containing a line break is always refused" do
    check all(head <- path(), tail <- path(), brk <- StreamData.member_of(["\n", "\r"])) do
      p = head <> brk <> tail
      fixup = %{path: p, uid: 0, gid: 0, mode: nil, drop_xattr: false}
      assert Debugfs.script([fixup]) == {:error, {:bad_image, {:unrepresentable_path, p}}}
    end
  end

  defp ext4_with(tmp, names) do
    src = Path.join(tmp, "src")
    File.mkdir_p!(src)
    Enum.each(names, &File.write!(Path.join(src, &1), "x"))
    img = Path.join(tmp, "fs.img")
    {_, 0} = System.cmd("mke2fs", ["-t", "ext4", "-F", "-q", "-d", src, img, "8M"])
    img
  end

  defp apply!(tmp, img, fixups) do
    {:ok, script} = Debugfs.script(fixups)
    script_path = Path.join(tmp, "script")
    File.write!(script_path, script)
    Debugfs.apply_script(img, script_path)
  end

  defp stat(img, path) do
    {out, 0} = System.cmd("debugfs", ["-R", ~s(stat "#{path}"), img], stderr_to_stdout: true)
    [_, mode] = Regex.run(~r/Mode:\s+(\d+)/, out)
    [_, uid, gid] = Regex.run(~r/User:\s+(\d+)\s+Group:\s+(\d+)/, out)
    {String.to_integer(mode, 8), String.to_integer(uid), String.to_integer(gid)}
  end

  test "applied to a real ext4, hostile names get exactly the requested owner and mode", %{
    tmp_dir: tmp
  } do
    names = ["plain", "with space", "q\"uote", "!bang", "café"]
    img = ext4_with(tmp, names)

    fixups =
      names
      |> Enum.with_index(1)
      |> Enum.map(fn {n, i} ->
        %{path: "/" <> n, uid: 1000 * i, gid: 70_000 + i, mode: 0o100000 ||| i, drop_xattr: true}
      end)

    assert :ok = apply!(tmp, img, fixups)

    for {n, i} <- Enum.with_index(names, 1),
        do: assert(stat(img, "/" <> String.replace(n, "\"", "\"\"")) == {i, 1000 * i, 70_000 + i})
  end

  test "a command debugfs rejects fails the apply", %{tmp_dir: tmp} do
    img = ext4_with(tmp, ["present"])
    fixup = %{path: "/absent", uid: 1, gid: 1, mode: nil, drop_xattr: false}

    assert {:error, {:debugfs_failed, 0, out}} = apply!(tmp, img, [fixup])
    assert out =~ "/absent"
  end
end
