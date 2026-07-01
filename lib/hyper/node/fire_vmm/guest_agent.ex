defmodule Hyper.Node.FireVMM.GuestAgent do
  @moduledoc """
  Resolves the path of the `hyper-guest-agent` static musl binary that the
  `:guest_agent_build` Mix compiler builds into `priv/guest-agent/` at compile
  time. The agent ships inside the app (and its release) -- there is no separate
  install step.

  The binary runs as guest PID 1 inside a Firecracker microVM and is baked into
  the rootfs before the VM boots. `path/1` is the single source of truth for
  where each arch's binary lives; `ensure_installed/0` verifies the binary for
  *this host's* arch is present and executable -- the only one a node needs,
  since KVM boots same-arch guests.
  """

  @doc "Absolute path to the guest-agent binary for `arch` (under the app's priv dir)."
  @spec path(Sys.Arch.t()) :: Path.t()
  def path(arch), do: Path.join(priv_dir(), "hyper-guest-agent-#{arch}")

  @doc """
  Returns `:ok` when the guest-agent binary for the current host arch is present
  and executable. Returns `{:error, {:not_installed, arch}}` if it is missing,
  `{:error, {:not_executable, arch}}` if it exists without an execute bit, or
  `{:error, {:unsupported_arch, raw}}` if the host arch is unrecognised.

  The binary is produced by the `:guest_agent_build` Mix compiler; a missing one
  means `mix compile` could not build it for this arch (see that compiler).
  """
  @spec ensure_installed() :: :ok | {:error, term()}
  def ensure_installed do
    with {:ok, arch} <- Sys.Arch.current() do
      p = path(arch)

      cond do
        not File.regular?(p) -> {:error, {:not_installed, arch}}
        not Sys.Posix.executable?(p) -> {:error, {:not_executable, arch}}
        true -> :ok
      end
    end
  end

  defp priv_dir, do: Path.join(:code.priv_dir(:hyper), "guest-agent")
end
