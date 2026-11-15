defmodule Hyper.Img.OciLoader.MtreePropertiesTest do
  @moduledoc """
  Laws of `Mtree.owners/1` over umoci's rootless mtree manifests:

    * oracle: for any tree of arbitrary byte names, rendered the way go-mtree
      writes it (vis-escaped names, `/set` defaults, `type=dir` descends, `..`
      ascends, comments), the owners are exactly the entries carrying a
      `user.rootlesscontainers` xattr, keyed by their unescaped relative path,
      with a missing protobuf field or the no-op id read as 0;
    * refusal: a malformed escape or a truncated/foreign protobuf is an error,
      never a silently dropped owner.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise

  alias Hyper.Img.OciLoader.Mtree

  @noop 0xFFFFFFFF

  defp name do
    StreamData.binary(min_length: 1, max_length: 6)
    |> StreamData.filter(&(&1 not in [".", ".."] and not String.contains?(&1, ["/", <<0>>])))
  end

  defp owner do
    id = StreamData.one_of([StreamData.integer(0..70_000), StreamData.constant(@noop)])
    StreamData.one_of([StreamData.constant(nil), StreamData.tuple({id, id})])
  end

  defp tree(0), do: StreamData.constant([])

  defp tree(depth) do
    entry =
      StreamData.tuple(
        {name(), owner(), StreamData.one_of([StreamData.constant(:file), tree(depth - 1)])}
      )

    StreamData.uniq_list_of(entry, uniq_fun: &elem(&1, 0), max_length: 4)
  end

  defp vis(name) do
    for <<byte <- name>>, into: "" do
      cond do
        byte == ?\\ -> "\\\\"
        byte in 0x21..0x7E and byte not in ~c"#*?[" -> <<byte>>
        true -> "\\" <> String.pad_leading(Integer.to_string(byte, 8), 3, "0")
      end
    end
  end

  defp varint(n) when n < 0x80, do: <<n>>
  defp varint(n), do: <<0x80 ||| band(n, 0x7F)>> <> varint(n >>> 7)

  defp field(_tag, 0), do: <<>>
  defp field(tag, n), do: varint(tag <<< 3) <> varint(n)

  defp xattr(nil), do: ""

  defp xattr({uid, gid}),
    do: " xattr.user.rootlesscontainers=" <> Base.encode64(field(1, uid) <> field(2, gid))

  defp render(entries, indent) do
    Enum.map(entries, fn
      {name, owner, :file} ->
        "#{indent}#{vis(name)} size=2 mode=0644#{xattr(owner)}\n"

      {name, owner, children} ->
        ["# comment\n", "#{vis(name)} type=dir mode=0755#{xattr(owner)}\n"] ++
          render(children, "    ") ++ ["..\n"]
    end)
  end

  defp expected(entries, prefix) do
    Enum.reduce(entries, %{}, fn {name, owner, kind}, acc ->
      path = if prefix == "", do: name, else: prefix <> "/" <> name
      acc = if owner, do: Map.put(acc, path, normalize(owner)), else: acc
      if kind == :file, do: acc, else: Map.merge(acc, expected(kind, path))
    end)
  end

  defp normalize({uid, gid}), do: {zero_noop(uid), zero_noop(gid)}
  defp zero_noop(@noop), do: 0
  defp zero_noop(n), do: n

  property "owners are exactly the xattr-carrying entries, keyed by unescaped path" do
    check all(root <- owner(), entries <- tree(3)) do
      text =
        IO.iodata_to_binary([
          "#          user: hyper\n\n",
          "/set type=file nlink=1 mode=0664 uid=1001 gid=1001\n",
          ". size=4096 type=dir mode=0755#{xattr(root)}\n",
          render(entries, "    "),
          "..\n"
        ])

      want =
        if root,
          do: Map.put(expected(entries, ""), "", normalize(root)),
          else: expected(entries, "")

      assert Mtree.owners(text) == {:ok, want}
    end
  end

  test "a manifest written by umoci 0.6 --rootless" do
    text = ~S"""
    #      keywords: size,type,uid,gid,mode,link,nlink,tar_time,sha256digest,xattr

    # .
    /set type=file nlink=1 mode=0664 uid=1001 gid=1001
    . size=4096 type=dir mode=0755 nlink=3 tar_time=0.000000000
        caf\303\251 size=2 mode=0644 tar_time=0.000000000 xattr.user.rootlesscontainers=CPCiBBDxogQ=
        ln size=3 type=link mode=0777 link=a\040b tar_time=0.000000000

    # a b
    a\040b size=4096 type=dir mode=0755 nlink=2 tar_time=0.000000000 xattr.user.rootlesscontainers=CAUQBg==
        q"x\\y\012z\052\043\133 size=2 mode=04755 tar_time=0.000000000 xattr.user.rootlesscontainers=EOgH
    ..
    ..
    """

    assert Mtree.owners(text) ==
             {:ok,
              %{
                "café" => {70_000, 70_001},
                "a b" => {5, 6},
                "a b/q\"x\\y\nz*#[" => {0, 1000}
              }}
  end

  test "malformed entries are refused" do
    for bad <- [
          ". type=dir xattr.user.rootlesscontainers=CA",
          ". type=dir xattr.user.rootlesscontainers=GAU=",
          ". type=dir xattr.user.rootlesscontainers=!!",
          "a\\9 size=1",
          "a\\ size=1",
          "a/b size=1",
          "a novalue"
        ] do
      assert {:error, {:mtree_unparsable, ^bad}} = Mtree.owners(bad <> "\n"), bad
    end
  end
end
