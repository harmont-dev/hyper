defmodule Hyper.Node.FireVMM.Jailer do
  @moduledoc """
  Builds the firecracker
  [jailer](https://github.com/firecracker-microvm/firecracker/blob/main/docs/jailer.md)
  command for one VM.

  The jailer sets up the chroot, namespaces, cgroup (via `Hyper.Vm.Instance`
  flags) and drops privileges, then exec's firecracker. We run the jailer (not
  firecracker directly) under `MuonTrap.Daemon`; MuonTrap only supervises the OS
  process, the jailer owns isolation.

  Because firecracker is chrooted to `<chroot_base>/<exec>/<id>/root`, the API
  socket it opens at `/api.socket` lives at `host_socket` on the host - that's the
  path the controller connects to.

  Host config: paths are derived from `config :hyper, work_dir: ...`. The
  firecracker + jailer binaries are installed under `<work_dir>/redist/firecracker`
  by `Hyper.Node.FireVMM.Provider`; the chroot base is `<work_dir>/jails`.
  """

  use OpenTelemetryDecorator

  alias Hyper.Node.FireVMM
  alias Hyper.Node.FireVMM.Provider
  alias Hyper.Vm.Instance

  # firecracker's API socket path *inside* the chroot.
  @jail_socket "api.socket"

  @type t :: %{binary: String.t(), args: [String.t()], host_socket: Path.t()}

  defmodule Checks do
    @moduledoc """
    Host pre-requisite checks for running the jailer. Each check returns
    `:ok | {:error, reason}`; `run/0` evaluates them in order and stops at the
    first failure.
    """

    alias Hyper.Config

    @doc "Run every pre-requisite check, halting at the first failure."
    @spec run() :: :ok | {:error, term()}
    def run do
      Enum.reduce_while(all(), :ok, fn check, :ok ->
        case check.() do
          :ok -> {:cont, :ok}
          {:error, _} = err -> {:halt, err}
        end
      end)
    end

    defp all do
      [
        &kvm_present/0,
        &cgroup_v2_available/0,
        &parent_cgroup_present/0,
        &chroot_writable/0
      ]
    end

    defp kvm_present do
      if File.exists?("/dev/kvm"), do: :ok, else: {:error, :kvm_unavailable}
    end

    defp parent_cgroup_present do
      if Sys.Linux.Cgroup.V2.named_exists?(Config.parent_cgroup()),
        do: :ok,
        else: {:error, :missing_parent_cgroup}
    end

    defp cgroup_v2_available do
      case Sys.Linux.Cgroup.versions() do
        {:ok, versions} ->
          if MapSet.member?(versions, :cgroup2), do: :ok, else: {:error, :cgroup_v2_unavailable}

        {:error, reason} ->
          {:error, {:cgroup_query_failed, reason}}
      end
    end

    defp chroot_writable do
      case Sys.Posix.ensure_writable_dir(Config.chroot_base()) do
        {:ok} -> :ok
        {:error, reason} -> {:error, {:chroot_base_unavailable, reason}}
      end
    end
  end

  @doc "Test whether the jailer and system pre-requisites are available."
  @spec test_system() :: :ok | {:error, term()}
  @decorate with_span("Hyper.Node.FireVMM.Jailer.test_system", include: [:result])
  def test_system, do: Checks.run()

  @spec command(FireVMM.Opts.t()) :: t()
  def command(opts) do
    args =
      [
        "--id",
        opts.vm_id,
        "--exec-file",
        Provider.firecracker_bin(),
        "--uid",
        to_string(opts.uid),
        "--gid",
        to_string(opts.gid),
        "--chroot-base-dir",
        Hyper.Config.chroot_base(),
        "--cgroup-version",
        "2",
        "--parent-cgroup",
        Hyper.Config.parent_cgroup()
      ] ++
        cgroup_flags(opts.type) ++
        ["--", "--api-sock", "/" <> @jail_socket]

    %{binary: Provider.jailer_bin(), args: args, host_socket: host_socket(opts.vm_id)}
  end

  # Find the appropriate jailer cgroup flags for the given instance type.
  @spec cgroup_flags(Instance.t()) :: [String.t()]
  defp cgroup_flags(type) do
    type
    |> Instance.spec()
    |> Instance.Spec.cgroup_v2()
    |> Sys.Linux.Cgroup.V2.Config.as_linux()
    |> Enum.flat_map(fn {file, value} -> ["--cgroup", "#{file}=#{value}"] end)
  end

  # Host-side path of the API socket firecracker opens inside the jail.
  # Note that we do not have control over where the jailer will place the socket so we need to
  # reconstruct the path here.
  @spec host_socket(String.t()) :: Path.t()
  defp host_socket(id) do
    Path.join([
      Hyper.Config.chroot_base(),
      exec_name(),
      id,
      "root",
      @jail_socket
    ])
  end

  defp exec_name, do: Path.basename(Provider.firecracker_bin())
end
