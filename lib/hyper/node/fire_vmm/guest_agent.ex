defmodule Hyper.Node.FireVMM.GuestAgent do
  @moduledoc """
  Resolves the per-arch path of the `hyper-guest-agent` static musl binary
  installed by `mix guest_agent.install`.

  The binary runs as guest PID 1 inside a Firecracker microVM and must be
  baked into the rootfs before the VM boots. `path/1` is the single source of
  truth for where each arch's binary lives; `ensure_installed/0` verifies that
  all expected binaries are present and executable before the node tries to use
  them.

  Install directory: `Hyper.Cfg.Dirs.guest_agent_install_dir/0`
  (`<work_dir>/redist/guest-agent`).
  """

  @doc "Absolute path to the installed guest-agent binary for `arch`."
  @spec path(Hyper.Vm.Instance.arch()) :: Path.t()
  def path(arch), do: Path.join(install_dir(), "hyper-guest-agent-#{arch}")

  @doc """
  Returns `:ok` when every supported-arch binary is present and executable.
  Returns `{:error, {:not_installed, arch}}` if a binary is missing, or
  `{:error, {:not_executable, arch}}` if a binary exists but has no execute bit.
  Run `mix guest_agent.install` to build and install both binaries.
  """
  @spec ensure_installed() :: :ok | {:error, term()}
  def ensure_installed do
    Hyper.Vm.Instance.arches()
    |> Enum.reduce_while(:ok, fn arch, :ok ->
      p = path(arch)

      cond do
        not File.regular?(p) -> {:halt, {:error, {:not_installed, arch}}}
        not Sys.Posix.executable?(p) -> {:halt, {:error, {:not_executable, arch}}}
        true -> {:cont, :ok}
      end
    end)
  end

  defp install_dir, do: Hyper.Cfg.Dirs.guest_agent_install_dir()
end
