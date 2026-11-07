defmodule Hyper.Test.SuidHelperStub do
  @moduledoc false

  import ExUnit.Callbacks, only: [on_exit: 1]

  @spec install!(Path.t(), String.t()) :: :ok
  def install!(dir, body) do
    script = Path.join(dir, "suidhelper-stub-#{System.unique_integer([:positive])}")
    File.write!(script, "#!/bin/sh\n#{body}\n")
    File.chmod!(script, 0o755)

    previous = Application.get_env(:hyper, Hyper.Cfg.Tools, [])
    Application.put_env(:hyper, Hyper.Cfg.Tools, Keyword.put(previous, :suidhelper, script))
    on_exit(fn -> Application.put_env(:hyper, Hyper.Cfg.Tools, previous) end)
  end
end
