defmodule Hyper.Node.Jailer do
  @moduledoc """
  Builds the firecracker
  [jailer](https://github.com/firecracker-microvm/firecracker/blob/main/docs/jailer.md)
  command for one VM.

  The jailer sets up the chroot, namespaces, cgroup (via `Hyper.Vm.Instance`
  flags) and drops privileges, then exec's firecracker. We run the jailer (not
  firecracker directly) under `MuonTrap.Daemon`; MuonTrap only supervises the OS
  process, the jailer owns isolation.

  Because firecracker is chrooted to `<chroot_base>/<exec>/<id>/root`, the API
  socket it opens at `/api.socket` lives at `host_socket` on the host — that's the
  path the controller connects to.

  Host config (`config :hyper, ...`): `:jailer_bin`, `:firecracker_bin`,
  `:jailer_chroot_base`, `:cgroup_parent`, `:jailer_uid`, `:jailer_gid`.
  """

  alias Hyper.Vm.Instance

  @cgroup_version 2
  # firecracker's API socket path *inside* the chroot.
  @jail_socket "api.socket"

  defmodule Opts do
    @moduledoc "Options to pass into the jailer command."

    defstruct [:vm_id, :uid, :gid, :type]

    @type t :: %__MODULE__{
            vm_id: integer(),
            uid: Hyper.Node.Users.id(),
            gid: Hyper.Node.Users.id(),
            type: Hyper.Vm.Instance.t()
          }
  end

  @type t :: %{binary: String.t(), args: [String.t()], host_socket: Path.t()}

  @spec command(Opts.t()) :: t()
  def command(opts) do
    args =
      [
        "--id",
        opts.vm_id,
        "--exec-file",
        Hyper.Config.firecracker_bin(),
        "--uid",
        to_string(opts.uid),
        "--gid",
        to_string(opts.gid),
        "--chroot-base-dir",
        Hyper.Config.chroot_base(),
        "--cgroup-version",
        to_string(@cgroup_version),
        "--parent-cgroup",
        Hyper.Config.parent_cgroup()
      ] ++
        cgroup_flags(opts.type) ++
        ["--", "--api-sock", "/" <> @jail_socket]

    %{binary: Hyper.Config.jailer_bin(), args: args, host_socket: host_socket(opts.vm_id)}
  end

  # Flatten the cgroup cap map into repeated `--cgroup file=value` jailer args.
  defp cgroup_flags(type) do
    Enum.flat_map(Instance.cgroup(type), fn {file, value} -> ["--cgroup", "#{file}=#{value}"] end)
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

  defp exec_name, do: Path.basename(Hyper.Config.firecracker_bin())
end
