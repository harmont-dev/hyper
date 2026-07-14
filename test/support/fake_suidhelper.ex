defmodule Hyper.Test.FakeSuidhelper do
  @moduledoc """
  Test harness for the setuid helper seam. `install!/1` writes a fake
  `hyper-suidhelper` (a bash script whose stdout JSON and exit code the caller
  scripts) and points `Hyper.Cfg.Tools.suidhelper/0` at it, so tests can drive
  `Hyper.SuidHelper.exec/1` and every tool submodule's decode/error path without
  root or a real device. The Toml cache is process-global, so callers must run
  `async: false`; `install!/1` restores the cache on test exit.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc """
  Write a fake helper running `body` (a bash snippet; argv arrives as `$1`,
  `$2`, …), route `tools.suidhelper` to it, and return its path. Restores the
  Toml cache and removes the script on test exit.
  """
  @spec install!(String.t()) :: Path.t()
  def install!(body) do
    path =
      Path.join(
        System.tmp_dir!(),
        "fake_suidhelper_#{System.unique_integer([:positive])}.sh"
      )

    File.write!(path, "#!/usr/bin/env bash\n" <> body <> "\n")
    File.chmod!(path, 0o755)
    Hyper.Cfg.Toml.put_cache(%{"tools" => %{"suidhelper" => path}})

    on_exit(fn ->
      Hyper.Cfg.Toml.reload()
      File.rm(path)
    end)

    path
  end
end
