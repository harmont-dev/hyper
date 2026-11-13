defmodule Hyper.Node.KernelGuard do
  @moduledoc """
  Boot guard refusing to host VMs on a kernel exposed to a known guest-to-host
  escape.

  A host is exposed to an advisory iff its vulnerable code is **reachable** and
  the kernel is **not provably fixed**:

    * **fixed** is judged from the upstream version alone: at or above the
      mainline release that first carried the fix, or at or above the fixed
      patch of a stable branch that received a backport. Distro kernels backport
      without bumping the version (`6.8.0-147-generic`), so they can never prove
      a fix this way — the guard errs towards "vulnerable", never "fixed". A
      version below the one that introduced the bug is unaffected.
    * **reachable** is the advisory's attack surface on this host:
      * `:x86_nested_mmu` — the x86 KVM shadow MMU, which a guest reaches only
        through nested virtualization; with `kvm_{intel,amd}.nested=0` it is
        unreachable on any kernel version. That is the remediation for distro
        kernels.
      * `:guest_network` — the host network stack behind every VM's
        virtio-net NIC. Networking is mandatory, so it is always reachable and
        only a provably fixed kernel (or the waiver) passes.

  An unknown version or nested state counts against the host. Operators can
  waive the guard wholesale with `Hyper.Cfg.Security.allow_vulnerable_kernel?/0`.
  """

  require Logger

  defmodule Advisory do
    @moduledoc """
    One kernel CVE. `fixed_in` maps a stable `{major, minor}` branch to its
    first fixed patch; `mainline` is the first release carrying the fix.
    """

    @type surface :: :x86_nested_mmu | :guest_network
    @type t :: %__MODULE__{
            id: String.t(),
            name: String.t(),
            surface: surface(),
            introduced: Sys.Linux.Kernel.version(),
            mainline: {non_neg_integer(), non_neg_integer()},
            fixed_in: %{{non_neg_integer(), non_neg_integer()} => non_neg_integer()}
          }
    @enforce_keys [:id, :name, :surface, :introduced, :mainline, :fixed_in]
    defstruct @enforce_keys
  end

  defmodule Host do
    @moduledoc "The host facts an advisory is judged against."

    @type t :: %__MODULE__{
            arch: Sys.Arch.t() | :unknown,
            version: Sys.Linux.Kernel.version() | :unknown,
            nested: boolean() | :unknown
          }
    @enforce_keys [:arch, :version, :nested]
    defstruct @enforce_keys
  end

  @doc "Every advisory the guard checks. Fixed versions are from the kernel.org CNA records."
  @spec advisories() :: [Advisory.t()]
  def advisories do
    [
      %Advisory{
        id: "CVE-2026-53359",
        name: "Januscape",
        surface: :x86_nested_mmu,
        introduced: {2, 6, 36},
        mainline: {7, 2},
        fixed_in: %{
          {5, 15} => 222,
          {6, 1} => 177,
          {6, 6} => 144,
          {6, 12} => 95,
          {6, 18} => 38,
          {7, 1} => 3
        }
      },
      %Advisory{
        id: "CVE-2026-64561",
        name: "Zapscape",
        surface: :x86_nested_mmu,
        introduced: {5, 9, 0},
        mainline: {7, 2},
        fixed_in: %{
          {5, 15} => 218,
          {6, 1} => 183,
          {6, 6} => 148,
          {6, 12} => 101,
          {6, 18} => 42,
          {7, 1} => 6
        }
      },
      %Advisory{
        id: "CVE-2026-99999",
        name: "PwnEscape",
        surface: :guest_network,
        introduced: {2, 6, 27},
        mainline: {7, 3},
        fixed_in: %{
          {5, 10} => 272,
          {5, 15} => 223,
          {6, 1} => 190,
          {6, 6} => 159,
          {6, 12} => 113,
          {6, 18} => 57,
          {7, 2} => 11
        }
      }
    ]
  end

  @doc """
  Refuse to boot (`{:error, {:vulnerable_kernel, ids}}`) when this host is
  exposed to any advisory, unless the operator waived the guard.
  """
  @spec check() :: :ok | {:error, {:vulnerable_kernel, [String.t()]}}
  def check, do: evaluate(host(), Hyper.Cfg.Security.allow_vulnerable_kernel?())

  @doc "Read this host's arch, kernel version, and KVM nested state."
  @spec host() :: Host.t()
  def host do
    %Host{
      arch: known(Sys.Arch.current()),
      version: known(Sys.Linux.Kernel.version()),
      nested: Sys.Linux.Kvm.nested()
    }
  end

  defp known({:ok, value}), do: value
  defp known({:error, _}), do: :unknown

  @doc "Apply the guard to `host`, logging every exposure. `allow?` waives refusal."
  @spec evaluate(Host.t(), boolean()) :: :ok | {:error, {:vulnerable_kernel, [String.t()]}}
  def evaluate(%Host{} = host, allow?) do
    case exposed(host, advisories()) do
      [] ->
        :ok

      hits when allow? ->
        Enum.each(hits, &Logger.warning("kernel guard waived: " <> describe(&1, host)))
        :ok

      hits ->
        Enum.each(hits, &Logger.error("kernel guard: " <> describe(&1, host)))
        {:error, {:vulnerable_kernel, Enum.map(hits, & &1.id)}}
    end
  end

  @doc "The advisories `host` is exposed to: reachable and not provably fixed."
  @spec exposed(Host.t(), [Advisory.t()]) :: [Advisory.t()]
  def exposed(%Host{} = host, advisories) do
    Enum.filter(advisories, &(reachable?(&1.surface, host) and not fixed?(&1, host.version)))
  end

  @doc "Whether `version` provably carries the fix for (or predates) `advisory`."
  @spec fixed?(Advisory.t(), Sys.Linux.Kernel.version() | :unknown) :: boolean()
  def fixed?(%Advisory{}, :unknown), do: false

  def fixed?(%Advisory{} = advisory, {maj, min, patch} = version) do
    cond do
      version < advisory.introduced -> true
      {maj, min} >= advisory.mainline -> true
      fixed_patch = advisory.fixed_in[{maj, min}] -> patch >= fixed_patch
      true -> false
    end
  end

  defp reachable?(:x86_nested_mmu, %Host{arch: arch, nested: nested}),
    do: arch != :aarch64 and nested != false

  defp reachable?(:guest_network, %Host{}), do: true

  defp describe(%Advisory{} = advisory, %Host{} = host) do
    "#{advisory.id} (#{advisory.name}) guest-to-host escape: kernel #{format(host.version)} " <>
      "is not provably fixed#{exposure(advisory.surface, host)}. " <>
      "Set [security] allow_vulnerable_kernel = true to boot anyway."
  end

  defp exposure(:x86_nested_mmu, %Host{nested: nested}) do
    " and KVM nested virtualization is #{nested_state(nested)}. " <>
      "Upgrade to a fixed kernel or disable nesting (options kvm_intel nested=0 / " <>
      "options kvm_amd nested=0 in /etc/modprobe.d, then reload the module)"
  end

  defp exposure(:guest_network, %Host{}),
    do: ", and every VM's virtio-net NIC reaches it. Upgrade to a fixed kernel"

  defp format({maj, min, patch}), do: "#{maj}.#{min}.#{patch}"
  defp format(:unknown), do: "(unknown version)"

  defp nested_state(true), do: "enabled"
  defp nested_state(:unknown), do: "not confirmed disabled"
end
