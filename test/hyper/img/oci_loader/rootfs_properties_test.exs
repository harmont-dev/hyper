defmodule Hyper.Img.OciLoader.RootfsPropertiesTest do
  @moduledoc """
  Laws of `Rootfs.unlock/1` and `Rootfs.fixups/2` over trees of arbitrary
  modes (including `0000` files and directories) and hard links:

    * after `unlock`, every directory is owner-`rwx` and every regular file
      owner-readable, so an unprivileged `mke2fs -d` can copy the whole tree;
    * the fixups restore the exact original mode of every inode `unlock`
      widened, and carry no mode for one it left alone;
    * every inode gets exactly one fixup, owned per the mtree owners (absent
      means `0:0`), and `/hyper-init` is last, `root:root` and `0755`, whatever
      the image had there.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise

  alias Hyper.Img.OciLoader.Rootfs

  @moduletag :tmp_dir

  @agent %{path: "/hyper-init", uid: 0, gid: 0, mode: 0o100755, drop_xattr: false}

  defp perm, do: StreamData.member_of([0o000, 0o111, 0o200, 0o444, 0o555, 0o600, 0o755, 0o4711])

  defp tree(0), do: StreamData.constant([])

  defp tree(depth) do
    kind = StreamData.one_of([StreamData.constant(:file), tree(depth - 1)])
    name = StreamData.string(:alphanumeric, min_length: 1, max_length: 4)
    entry = StreamData.tuple({name, perm(), kind, StreamData.boolean()})
    StreamData.uniq_list_of(entry, uniq_fun: &elem(&1, 0), max_length: 4)
  end

  defp flatten(entries, prefix) do
    Enum.flat_map(entries, fn {name, perm, kind, linked} ->
      rel = Path.join(prefix, name)
      type = if kind == :file, do: :regular, else: :directory

      names =
        if type == :regular and linked, do: [rel, Path.join(prefix, "hl-" <> name)], else: [rel]

      me = %{names: names, type: type, perm: perm}
      if type == :regular, do: [me], else: [me | flatten(kind, rel)]
    end)
  end

  defp build!(root, model) do
    for %{names: [first | links], type: type} <- model do
      path = Path.join(root, first)
      if type == :regular, do: File.write!(path, first), else: File.mkdir!(path)
      Enum.each(links, &File.ln!(path, Path.join(root, &1)))
    end

    for %{names: [first | _], perm: perm} <- Enum.reverse(model),
        do: File.chmod!(Path.join(root, first), perm)
  end

  defp owner(perm), do: if(band(perm, 0o100) != 0, do: {perm, perm + 1})

  defp needed(:directory), do: 0o700
  defp needed(:regular), do: 0o400

  defp ifmt(:directory), do: 0o040000
  defp ifmt(:regular), do: 0o100000

  property "unlock makes the tree copyable and the fixups restore it exactly", %{tmp_dir: tmp} do
    check all(entries <- tree(3), root_perm <- perm(), image_agent <- StreamData.boolean()) do
      root = Path.join(tmp, "r#{System.unique_integer([:positive])}")
      File.mkdir!(root)
      if image_agent, do: File.write!(Path.join(root, "hyper-init"), "image's own")

      model = [%{names: [""], type: :directory, perm: root_perm} | flatten(entries, "")]
      build!(root, tl(model))
      File.chmod!(root, root_perm)

      owners =
        for %{names: names, perm: perm} <- model,
            owner(perm),
            name <- names,
            into: %{},
            do: {name, owner(perm)}

      assert {:ok, unlocked} = Rootfs.unlock(root)

      for path <- [root | Path.wildcard(Path.join(root, "**"), match_dot: true)] do
        stat = File.lstat!(path)
        assert band(stat.mode, needed(stat.type)) == needed(stat.type), path
      end

      fixups = Rootfs.fixups(unlocked, owners)
      assert List.last(fixups) == @agent
      assert length(fixups) == length(model) + 1

      by_path = Map.new(fixups, &{&1.path, &1})

      for %{names: names, type: type, perm: perm} <- model do
        assert [fixup] = Enum.flat_map(names, &List.wrap(by_path["/" <> &1])), inspect(names)

        widened = band(perm, needed(type)) != needed(type)
        assert fixup.mode == if(widened, do: ifmt(type) ||| perm)
        assert {fixup.uid, fixup.gid} == (owner(perm) || {0, 0})
        assert fixup.drop_xattr == (owner(perm) != nil)
      end
    end
  end
end
