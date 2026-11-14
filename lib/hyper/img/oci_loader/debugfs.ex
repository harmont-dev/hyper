defmodule Hyper.Img.OciLoader.Debugfs do
  @moduledoc false

  @type fixup :: %{
          path: Path.t(),
          uid: non_neg_integer(),
          gid: non_neg_integer(),
          mode: non_neg_integer() | nil,
          drop_xattr: boolean()
        }

  # debugfs reads its command file in BUFSIZ (8 KiB) chunks and runs whatever
  # follows a split as a fresh command, so every line must fit well inside one.
  @max_quoted_path 4000

  @spec script([fixup()]) :: {:ok, iodata()} | {:error, {:bad_image, term()}}
  def script(fixups) do
    Enum.reduce_while(fixups, {:ok, []}, fn fixup, {:ok, acc} ->
      case commands(fixup) do
        {:ok, lines} -> {:cont, {:ok, [acc | lines]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  @spec apply_script(Path.t(), Path.t()) :: :ok | {:error, term()}
  def apply_script(img, script_path) do
    # debugfs exits 0 even when a command fails and reports failures only on
    # stderr, so stdout (the command echo) is discarded and stderr kept.
    {out, status} =
      System.cmd("sh", [
        "-c",
        ~s(exec "$0" -w -f "$1" "$2" 2>&1 >/dev/null),
        Hyper.Cfg.Tools.debugfs(),
        script_path,
        img
      ])

    case {status, String.split(out, "\n", trim: true)} do
      {0, [<<"debugfs ", _::binary>>]} -> :ok
      {0, []} -> :ok
      _ -> {:error, {:debugfs_failed, status, out}}
    end
  end

  defp commands(%{path: path} = fixup) do
    with {:ok, quoted} <- quote_path(path) do
      lines =
        [
          ["sif ", quoted, " uid ", Integer.to_string(fixup.uid), ?\n],
          ["sif ", quoted, " gid ", Integer.to_string(fixup.gid), ?\n],
          if(fixup.mode, do: ["sif ", quoted, " mode 0", Integer.to_string(fixup.mode, 8), ?\n]),
          if(fixup.drop_xattr, do: ["ea_rm ", quoted, " user.rootlesscontainers\n"])
        ]

      {:ok, Enum.reject(lines, &is_nil/1)}
    end
  end

  defp quote_path(path) do
    quoted = ~s(") <> String.replace(path, ~s("), ~s("")) <> ~s(")

    cond do
      String.contains?(path, ["\n", "\r"]) ->
        {:error, {:bad_image, {:unrepresentable_path, path}}}

      byte_size(quoted) > @max_quoted_path ->
        {:error, {:bad_image, {:path_too_long, path}}}

      true ->
        {:ok, quoted}
    end
  end
end
