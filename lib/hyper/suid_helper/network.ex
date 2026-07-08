defmodule Hyper.SuidHelper.Network do
  @moduledoc """
  Privileged per-VM egress networking via the setuid helper's `network`
  subcommands. The helper derives every address, interface name, and netns path
  from `vm_id` + the validated `uid` + the root-owned `[network]` config — the
  node passes only those two untrusted values.
  """
  use OpenTelemetryDecorator
  alias Hyper.SuidHelper

  @type err :: SuidHelper.err()

  @doc false
  @spec argv(:prepare | :teardown, Hyper.Vm.Id.t(), non_neg_integer()) :: [String.t()]
  def argv(op, vm_id, uid),
    do: ["network", Atom.to_string(op), "--vm-id", vm_id, "--uid", to_string(uid)]

  @doc "Create `vm_id`'s netns, veth pair, TAP, and NAT rules. Idempotent-safe on relaunch."
  @spec prepare(Hyper.Vm.Id.t(), non_neg_integer()) :: :ok | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Network.prepare", include: [:vm_id, :uid])
  def prepare(vm_id, uid), do: run(argv(:prepare, vm_id, uid))

  @doc "Remove `vm_id`'s netns and host veth. Idempotent (a never-prepared VM is a no-op)."
  @spec teardown(Hyper.Vm.Id.t(), non_neg_integer()) :: :ok | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Network.teardown", include: [:vm_id, :uid])
  def teardown(vm_id, uid), do: run(argv(:teardown, vm_id, uid))

  @doc "Ensure the host-wide `hyper` nft table (masquerade + forward policy) exists. Idempotent."
  @spec host_init() :: :ok | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Network.host_init", include: [])
  def host_init, do: run(["network", "host-init"])

  @spec run([String.t()]) :: :ok | {:error, err()}
  defp run(args) do
    case SuidHelper.exec(args) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end
end
