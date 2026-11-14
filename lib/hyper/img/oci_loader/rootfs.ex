defmodule Hyper.Img.OciLoader.Rootfs do
  @moduledoc false

  import Bitwise

  alias Hyper.Img.OciLoader.{Debugfs, Mtree}

  @type entry :: %{
          path: Path.t(),
          ino: non_neg_integer(),
          mode: non_neg_integer(),
          widened: boolean()
        }

  @agent "hyper-init"
  @agent_mode 0o100755

  @spec unlock(Path.t()) :: {:ok, [entry()]} | {:error, term()}
  def unlock(rootfs) do
    with {:ok, acc} <- visit(rootfs, "", []), do: {:ok, Enum.reverse(acc)}
  end

  @spec fixups([entry()], Mtree.owners()) :: [Debugfs.fixup()]
  def fixups(entries, owners) do
    first_seen = Enum.reduce(entries, %{}, &Map.put_new(&2, &1.ino, &1))

    entries
    |> Enum.reject(&(&1.path == @agent))
    |> Enum.uniq_by(& &1.ino)
    |> Enum.map(fn %{path: path, ino: ino} ->
      original = Map.fetch!(first_seen, ino)
      owner = Map.get(owners, path)
      {uid, gid} = owner || {0, 0}

      %{
        path: "/" <> path,
        uid: uid,
        gid: gid,
        mode: if(original.widened, do: original.mode),
        drop_xattr: owner != nil
      }
    end)
    |> Kernel.++([%{path: "/" <> @agent, uid: 0, gid: 0, mode: @agent_mode, drop_xattr: false}])
  end

  defp visit(abs, rel, acc) do
    with {:ok, %File.Stat{type: type, mode: mode, inode: ino}} <- File.lstat(abs),
         {:ok, widened} <- widen(abs, type, mode) do
      acc = [%{path: rel, ino: ino, mode: mode, widened: widened} | acc]
      if type == :directory, do: children(abs, rel, acc), else: {:ok, acc}
    end
  end

  defp children(abs, rel, acc) do
    with {:ok, names} <- :file.list_dir_all(abs) do
      Enum.reduce_while(names, {:ok, acc}, fn name, {:ok, acc} ->
        name = IO.chardata_to_string(name)
        child = if rel == "", do: name, else: rel <> "/" <> name

        case visit(Path.join(abs, name), child, acc) do
          {:ok, _} = ok -> {:cont, ok}
          {:error, _} = err -> {:halt, err}
        end
      end)
    end
  end

  defp widen(abs, :directory, mode), do: ensure_bits(abs, mode, 0o700)
  defp widen(abs, :regular, mode), do: ensure_bits(abs, mode, 0o400)
  defp widen(_abs, _type, _mode), do: {:ok, false}

  defp ensure_bits(_abs, mode, bits) when band(mode, bits) == bits, do: {:ok, false}

  defp ensure_bits(abs, mode, bits) do
    with :ok <- File.chmod(abs, band(mode, 0o7777) ||| bits), do: {:ok, true}
  end
end
