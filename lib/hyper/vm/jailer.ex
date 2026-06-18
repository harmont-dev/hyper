defmodule Hyper.Vm.Jailer do
  @moduledoc """
  Builds the firecracker [jailer](https://github.com/firecracker-microvm/firecracker/blob/main/docs/jailer.md)
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
  @jail_socket "/api.socket"

  @type t :: %{binary: String.t(), args: [String.t()], host_socket: Path.t()}

  @spec command(%{:id => String.t(), :type => Instance.t(), optional(any()) => any()}) :: t()
  def command(%{id: id, type: type}) do
    args =
      [
        "--id", id,
        "--exec-file", firecracker_bin(),
        "--uid", to_string(uid()),
        "--gid", to_string(gid()),
        "--chroot-base-dir", chroot_base(),
        "--cgroup-version", to_string(@cgroup_version),
        "--parent-cgroup", parent_cgroup()
      ] ++
        Instance.cgroup(type, @cgroup_version) ++
        ["--", "--api-sock", @jail_socket]

    %{binary: jailer_bin(), args: args, host_socket: host_socket(id)}
  end

  @doc "Host-side path of the API socket firecracker opens inside the jail."
  @spec host_socket(String.t()) :: Path.t()
  def host_socket(id), do: Path.join([chroot_base(), exec_name(), id, "root", String.trim_leading(@jail_socket, "/")])

  defp exec_name, do: Path.basename(firecracker_bin())

  defp jailer_bin, do: Application.get_env(:hyper, :jailer_bin, "jailer")
  defp firecracker_bin, do: Application.get_env(:hyper, :firecracker_bin, "/usr/bin/firecracker")
  defp chroot_base, do: Application.get_env(:hyper, :jailer_chroot_base, "/srv/jailer")
  defp parent_cgroup, do: Application.get_env(:hyper, :cgroup_parent, "hyper")
  defp uid, do: Application.get_env(:hyper, :jailer_uid, 1000)
  defp gid, do: Application.get_env(:hyper, :jailer_gid, 1000)
end
