defmodule Sys.Tmp do
  @moduledoc """
  Temporary file/directory helpers.

  Names carry the caller's `prefix` (so leaked entries are identifiable) plus
  a cryptographically random component, and creation is exclusive (`O_EXCL` /
  plain `mkdir`) with retry-on-collision — so concurrent callers, other OS
  processes, VM restarts, and pre-planted paths (symlinks in a world-writable
  tmp dir) can never hand a caller a path someone else controls.
  """

  # Collisions against 8 random bytes mean the tmp dir is adversarial or the
  # RNG is broken; a handful of retries distinguishes bad luck from either.
  @attempts 8

  require Logger

  @doc """
  Create a fresh temporary directory, pass its path to `fun`, and remove it
  (recursively) afterward - even if `fun` raises. Returns whatever `fun`
  returns.
  """
  @spec with_tempdir(String.t(), (Path.t() -> result)) :: result when result: var
  def with_tempdir(prefix \\ "hyper", fun) when is_function(fun, 1) do
    dir = create_exclusive!(prefix, &mkdir_private/1, @attempts)

    try do
      fun.(dir)
    after
      remove_tree(dir)
    end
  end

  @doc """
  Create a fresh empty temporary file, pass its path to `fun`, and remove it
  afterward - even if `fun` raises. Returns whatever `fun` returns.
  """
  @spec with_tmpfile(String.t(), (Path.t() -> result)) :: result when result: var
  def with_tmpfile(prefix \\ "hyper", fun) when is_function(fun, 1) do
    path = create_exclusive!(prefix, &touch_exclusive/1, @attempts)

    try do
      fun.(path)
    after
      _ = File.rm(path)
    end
  end

  @spec remove_tree(Path.t()) :: :ok
  defp remove_tree(dir) do
    make_traversable(dir)

    case File.rm_rf(dir) do
      {:ok, _removed} ->
        :ok

      {:error, reason, path} ->
        Logger.warning("tmp: failed to remove #{path} under #{dir}: #{inspect(reason)}")
    end
  end

  @spec make_traversable(Path.t()) :: :ok
  defp make_traversable(path) do
    with {:ok, %File.Stat{type: :directory}} <- File.lstat(path),
         _ = File.chmod(path, 0o700),
         {:ok, entries} <- File.ls(path) do
      Enum.each(entries, &make_traversable(Path.join(path, &1)))
    else
      _ -> :ok
    end
  end

  # O_CREAT|O_EXCL: fails :eexist on any pre-existing path, symlinks included.
  @spec mkdir_private(Path.t()) :: :ok | {:error, File.posix()}
  defp mkdir_private(path) do
    with :ok <- File.mkdir(path), do: File.chmod(path, 0o700)
  end

  @spec touch_exclusive(Path.t()) :: :ok | {:error, File.posix()}
  defp touch_exclusive(path) do
    case File.open(path, [:write, :exclusive]) do
      {:ok, io} -> File.close(io)
      {:error, _} = err -> err
    end
  end

  @spec create_exclusive!(String.t(), (Path.t() -> :ok | {:error, File.posix()}), pos_integer()) ::
          Path.t()
  defp create_exclusive!(prefix, create, attempts) do
    suffix = Base.encode32(:crypto.strong_rand_bytes(8), case: :lower, padding: false)
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{suffix}")

    case create.(path) do
      :ok ->
        path

      {:error, :eexist} when attempts > 1 ->
        create_exclusive!(prefix, create, attempts - 1)

      {:error, reason} ->
        raise File.Error, reason: reason, action: "create temporary path", path: path
    end
  end
end
