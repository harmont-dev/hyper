defmodule Hyper.Node.FireVMM.Core do
  @moduledoc """
  The lifecycle-coupled core of one microVM: the jailed firecracker daemon and
  its controller, restarted as a pair. Isolated from the API client
  (`Hyper.Node.FireVMM.Client`) so the *only* order-sensitive relationship in the
  VM tree lives in this two-child supervisor.

    1. `Hyper.Node.FireVMM.Daemon` - the jailer OS process (under `MuonTrap`).
       MUST be the first child: it must be (re)started before the controller so
       the API socket is coming up by the time the controller probes.
    2. `Hyper.Node.FireVMM.State` - the `:gen_statem` controller; drives the boot
       protocol (await API -> stage -> configure -> run) against that daemon.

  `:one_for_all`, daemon first: a crash of *either* child takes both down and
  restarts the pair. So:

    * controller crash -> daemon also discarded; no orphaned VM, fresh cold boot.
    * firecracker crash -> the `Daemon` child exits; both restart; `Daemon`
      resets the stale jail and relaunches, and the fresh controller cold-boots.

  `Daemon` guarantees firecracker is dead on teardown via the helper's
  `cgroup.kill` (MuonTrap's port-close kill misses the setsid'd firecracker), so
  no firecracker process outlives a graceful supervisor shutdown.
  """

  use Supervisor

  alias Hyper.Node.FireVMM
  alias Hyper.Node.FireVMM.Daemon
  alias Hyper.Node.FireVMM.State

  # Started unnamed: nothing resolves the core by name (it is addressed as a
  # child of `Hyper.Node.FireVMM`), so it needs no registry entry - and avoids a
  # needless racy Horde registration at startup.
  @spec start_link(FireVMM.Opts.t()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    children = [
      {Daemon, opts},
      {State, opts}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
