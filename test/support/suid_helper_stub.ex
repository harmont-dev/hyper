defmodule Hyper.Test.SuidHelperStub do
  @moduledoc false

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Hyper.Cfg.Toml

  @spec install!(Path.t(), String.t(), map()) :: :ok
  def install!(dir, body, toml \\ Toml.reload()) do
    script = Path.join(dir, "suidhelper-stub-#{System.unique_integer([:positive])}")
    File.write!(script, "#!/bin/sh\n#{body}\n")
    File.chmod!(script, 0o755)

    Toml.put_cache(put_in(toml, [Access.key("tools", %{}), "suidhelper"], script))
    on_exit(fn -> Toml.put_cache(toml) end)
  end
end
