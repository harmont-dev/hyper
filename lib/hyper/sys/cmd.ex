defmodule Hyper.Sys.Cmd do
  @moduledoc """
  Runs privileged device commands, optionally through the configured setuid device
  helper (`Hyper.Config.device_helper/0`).

  When a helper is configured, `run/1` invokes `<helper> <bin> <args...>` and the
  helper is responsible for whitelisting/validating before executing as root.
  When no helper is configured the command runs directly — appropriate when the
  node itself runs as root (e.g. dev).
  """

  @doc "Run `[bin | args]`, returning `{combined_output, exit_code}`."
  @spec run([String.t(), ...]) :: {String.t(), non_neg_integer()}
  def run([bin | args]) do
    case Hyper.Config.device_helper() do
      nil ->
        System.cmd(bin, args, stderr_to_stdout: true)

      helper ->
        # The helper execs the absolute path we pass via `--bin` (verified there:
        # root-owned, basename matches the subcommand). In helper mode the
        # configured tool paths must therefore be absolute.
        System.cmd(helper, ["--bin", bin, Path.basename(bin) | args], stderr_to_stdout: true)
    end
  end
end
