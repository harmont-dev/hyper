defmodule Hyper.Sys.Posix do
  @moduledoc "POSIX filesystem helpers."

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
end
