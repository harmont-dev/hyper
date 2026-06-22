defmodule Hyper.SuidHelper do
  @moduledoc """
  Interface to the setuid-root device helper (`hyper-suidhelper`).

  The node runs unprivileged; this helper is the only path to the privileged
  `losetup`/`dmsetup`/`blockdev` operations. Each call shells the configured
  helper for one operation - `<helper> <tool> --bin <tool_bin> <args...>` - and
  decodes the JSON object it prints on success. The helper validates every
  argument before it briefly escalates to root (see `native/suidhelper`).
  """

  @typedoc "The JSON object the helper prints on success."
  @type result :: %{optional(String.t()) => term()}

  @binless ~w(mknod stage)

  @doc """
  Run one helper subcommand. `tool` is the subcommand (`"losetup"`, `"dmsetup"`,
  `"blockdev"`, `"mknod"`, `"stage"`), `tool_bin` the absolute path to the real binary it execs, and
  `args` the operation's arguments. Returns the decoded JSON object, or
  `{:error, {exit_code, message}}` when the helper exits non-zero.
  """
  @spec run(String.t(), Path.t(), [String.t()]) ::
          {:ok, result()} | {:error, {non_neg_integer(), String.t()}}
  def run(tool, tool_bin, args) do
    argv =
      if tool in @binless,
        do: [tool | args],
        else: [tool, "--bin", tool_bin | args]

    # stderr_to_stdout: on success the helper writes only the JSON line to stdout;
    # on failure it writes the message to stderr and exits non-zero. Merging lets
    # us capture either with one call.
    case System.cmd(Hyper.Config.suid_helper(), argv, stderr_to_stdout: true) do
      {out, 0} -> {:ok, Jason.decode!(out)}
      {out, code} -> {:error, {code, String.trim(out)}}
    end
  end
end
