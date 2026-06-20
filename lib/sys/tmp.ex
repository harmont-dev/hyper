defmodule Sys.Tmp do
  @moduledoc "Temporary directory helpers."

  @doc """
  Create a fresh temporary directory, pass its path to `fun`, and remove it
  (recursively) afterward - even if `fun` raises. Returns whatever `fun` returns.

  `prefix` is used to name the directory, which helps identify leaked temp dirs.
  """
  @spec with_tempdir(String.t(), (Path.t() -> result)) :: result when result: var
  def with_tempdir(prefix \\ "hyper", fun) when is_function(fun, 1) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      fun.(dir)
    after
      File.rm_rf!(dir)
    end
  end
end
