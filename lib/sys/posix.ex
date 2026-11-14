defmodule Sys.Posix do
  @moduledoc "POSIX filesystem helpers."

  @private_dir_mode 0o700
  @private_file_mode 0o600

  @doc "Check whether a file exists and is executable."
  @spec executable?(Path.t()) :: boolean()
  def executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  @doc """
  Test whether an existing file is a directory that the current user can write to, and if it
  doesn't exist, create it, including any parents.
  """
  @spec ensure_writable_dir(Path.t()) :: {:ok} | {:error, atom()}
  def ensure_writable_dir(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory, access: access}} when access in [:write, :read_write] ->
        {:ok}

      {:ok, %File.Stat{type: :directory}} ->
        {:error, :eacces}

      {:ok, %File.Stat{}} ->
        {:error, :enotdir}

      {:error, :enoent} ->
        case File.mkdir_p(path) do
          :ok -> {:ok}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec private_file_mode :: 0o600
  def private_file_mode, do: @private_file_mode

  @spec mkdir_private(Path.t()) :: :ok | {:error, File.posix()}
  def mkdir_private(path) do
    case File.mkdir(path) do
      :ok ->
        File.chmod(path, @private_dir_mode)

      {:error, :eexist} ->
        if File.dir?(path), do: :ok, else: {:error, :eexist}

      {:error, :enoent} ->
        with :ok <- mkdir_private(Path.dirname(path)), do: mkdir_private(path)

      {:error, _} = err ->
        err
    end
  end

  # O_CREAT|O_EXCL: fails :eexist on any pre-existing path, symlinks included.
  @spec create_private_file(Path.t()) :: :ok | {:error, File.posix()}
  def create_private_file(path) do
    case File.open(path, [:write, :exclusive]) do
      {:ok, io} ->
        :ok = File.close(io)
        File.chmod(path, @private_file_mode)

      {:error, _} = err ->
        err
    end
  end

  @spec ensure_private_file(Path.t()) :: :ok | {:error, File.posix()}
  def ensure_private_file(path) do
    case create_private_file(path) do
      {:error, :eexist} -> File.chmod(path, @private_file_mode)
      result -> result
    end
  end
end
