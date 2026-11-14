defmodule Hyper.Node.WorkDir do
  @moduledoc false

  alias Hyper.Cfg.Dirs
  alias Hyper.Node.WorkDir.Plan

  require Logger

  @spec secure :: :ok | {:error, {:work_dir, String.t()}}
  def secure do
    with :ok <- create_dirs(),
         {:ok, uid} <- node_uid(),
         {:ok, entries} <- entries(),
         {:ok, changes} <- plan(entries, uid) do
      Enum.reduce_while(changes, :ok, &apply_change/2)
    end
  end

  @spec created_dirs :: [Path.t()]
  defp created_dirs, do: [Dirs.scratch_dir(), Dirs.redist_dir(), Dirs.chroot_base()]

  @spec private_dirs :: [Path.t()]
  defp private_dirs, do: Enum.uniq([Dirs.work_dir(), Dirs.layer_dir() | created_dirs()])

  @spec data_dirs :: [Path.t()]
  defp data_dirs, do: Enum.uniq([Dirs.scratch_dir(), Dirs.layer_dir()])

  @spec create_dirs :: :ok | {:error, {:work_dir, String.t()}}
  defp create_dirs do
    Enum.reduce_while(created_dirs(), :ok, fn dir, :ok ->
      case Sys.Posix.mkdir_private(dir) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, refuse("cannot create #{dir}: #{format(reason)}")}
      end
    end)
  end

  @spec node_uid :: {:ok, non_neg_integer()} | {:error, {:work_dir, String.t()}}
  defp node_uid do
    with {out, 0} <- System.cmd("id", ["-u"], stderr_to_stdout: true),
         {:ok, uid} <- Num.Int.parse_unsigned(String.trim(out)) do
      {:ok, uid}
    else
      _ -> refuse("cannot determine the uid Hyper runs as (`id -u` failed)")
    end
  end

  @spec entries :: {:ok, [Plan.entry()]} | {:error, {:work_dir, String.t()}}
  defp entries do
    with {:ok, dirs} <- stat_all(private_dirs(), :dir, &File.stat/1),
         {:ok, files} <- data_files() do
      {:ok, dirs ++ files}
    end
  end

  @spec data_files :: {:ok, [Plan.entry()]} | {:error, {:work_dir, String.t()}}
  defp data_files do
    Enum.reduce_while(data_dirs(), {:ok, []}, fn dir, {:ok, acc} ->
      with {:ok, names} <- list(dir),
           {:ok, entries} <- stat_all(Enum.map(names, &Path.join(dir, &1)), :data, &File.lstat/1) do
        {:cont, {:ok, acc ++ Enum.filter(entries, &regular?/1)}}
      else
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  @spec list(Path.t()) :: {:ok, [String.t()]} | {:error, {:work_dir, String.t()}}
  defp list(dir) do
    case File.ls(dir) do
      {:ok, names} -> {:ok, Enum.sort(names)}
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> refuse("cannot list #{dir}: #{format(reason)}")
    end
  end

  @spec regular?(Plan.entry()) :: boolean()
  defp regular?({_path, _kind, %File.Stat{type: type}}), do: type == :regular

  @spec stat_all([Path.t()], Plan.kind(), (Path.t() -> {:ok, File.Stat.t()} | {:error, atom()})) ::
          {:ok, [Plan.entry()]} | {:error, {:work_dir, String.t()}}
  defp stat_all(paths, kind, stat) do
    paths
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
      case stat.(path) do
        {:ok, %File.Stat{} = st} -> {:cont, {:ok, [{path, kind, st} | acc]}}
        {:error, :enoent} -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, refuse("cannot stat #{path}: #{format(reason)}")}
      end
    end)
    |> then(fn
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, _} = err -> err
    end)
  end

  @spec plan([Plan.entry()], non_neg_integer()) ::
          {:ok, [Plan.change()]} | {:error, {:work_dir, String.t()}}
  defp plan(entries, uid) do
    case Plan.plan(entries, uid) do
      {:ok, changes} ->
        {:ok, changes}

      {:error, {:not_a_directory, path}} ->
        refuse("#{path} is not a directory; fix: move it aside and restart")

      {:error, {:not_owned, path, owner, mode}} ->
        refuse(
          "#{path} is owned by uid #{owner} with mode #{octal(mode)}, so Hyper (uid #{uid}) " <>
            "cannot make it private; fix: sudo chown #{uid} #{path} and restart"
        )
    end
  end

  @spec apply_change(Plan.change(), :ok) ::
          {:cont, :ok} | {:halt, {:error, {:work_dir, String.t()}}}
  defp apply_change({path, from, to}, :ok) do
    case File.chmod(path, to) do
      :ok ->
        Logger.warning("work_dir: tightened #{path} from #{octal(from)} to #{octal(to)}")
        {:cont, :ok}

      {:error, reason} ->
        {:halt, refuse("cannot chmod #{path} to #{octal(to)}: #{format(reason)}")}
    end
  end

  @spec refuse(String.t()) :: {:error, {:work_dir, String.t()}}
  defp refuse(message) do
    Logger.error("work_dir: #{message}")
    {:error, {:work_dir, message}}
  end

  @spec octal(Plan.mode()) :: String.t()
  defp octal(mode), do: mode |> Integer.to_string(8) |> String.pad_leading(4, "0")

  @spec format(atom()) :: String.t()
  defp format(reason), do: reason |> :file.format_error() |> to_string()
end
