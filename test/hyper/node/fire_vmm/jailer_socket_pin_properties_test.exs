defmodule Hyper.Node.FireVMM.JailerSocketPinPropertiesTest do
  @moduledoc """
  The BEAM-side half of the socket-pin contract from #135.

  Laws:

    * wire contract with the helper: for every work dir and VM id, `host_socket/1`
      and `host_vsock/1` are exactly the pins the helper's claim ops create,
      `<work_dir>/socks/fc-<id>-api.socket` and `<work_dir>/socks/fc-<id>-vsock.sock`
      (Rust: `Config::socket_dir` joined with `SocketPin::name`);
    * the BEAM never dials a jail path: neither pin lies under `chroot_base/0`;
    * naming is injective: no two `(id, socket)` pairs, nor a pin and a relay
      socket, share a path, so one VM's teardown or claim can never hit another's;
    * reclaim sweeps exactly what Hyper names: after a reboot every Firecracker pin
      and relay socket for any set of VMs is removed, and every look-alike survives.

  `async: false` because the work dir is set through `Hyper.Cfg.Toml.put_cache/1`,
  which is process-global.
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Hyper.Node.FireVMM.{Agent, Jailer}
  alias Hyper.Node.Reclaim

  setup do
    original = Hyper.Cfg.Toml.reload()
    on_exit(fn -> Hyper.Cfg.Toml.put_cache(original) end)
    {:ok, original: original}
  end

  defp vm_id do
    StreamData.string(Enum.concat(?a..?z, ?2..?7), min_length: 1, max_length: 16)
    |> StreamData.map(&("v" <> &1))
  end

  defp work_dir do
    StreamData.string(:alphanumeric, min_length: 1, max_length: 12)
    |> StreamData.list_of(min_length: 1, max_length: 4)
    |> StreamData.map(&Path.join(["/", "srv-prop" | &1]))
  end

  defp with_work_dir(original, dir),
    do: Hyper.Cfg.Toml.put_cache(Map.put(original, "work_dir", dir))

  property "the BEAM dials exactly the pins the helper creates, never a jail path",
           %{original: original} do
    check all(dir <- work_dir(), id <- vm_id()) do
      with_work_dir(original, dir)

      assert {Jailer.host_socket(id), Jailer.host_vsock(id)} ==
               {"#{dir}/socks/fc-#{id}-api.socket", "#{dir}/socks/fc-#{id}-vsock.sock"}

      chroot = Hyper.Cfg.Dirs.chroot_base() <> "/"
      refute String.starts_with?(Jailer.host_socket(id), chroot)
      refute String.starts_with?(Jailer.host_vsock(id), chroot)
    end
  end

  property "no two VMs or socket kinds share a socket path", %{original: original} do
    with_work_dir(original, "/srv/hyper")

    check all(ids <- StreamData.uniq_list_of(vm_id(), min_length: 2, max_length: 12)) do
      paths =
        Enum.flat_map(ids, fn id ->
          [Jailer.host_socket(id), Jailer.host_vsock(id), Agent.relay_socket_path(id)]
        end)

      assert length(Enum.uniq(paths)) == 3 * length(ids)
    end
  end

  property "reclaim removes every pin and relay socket Hyper names and spares look-alikes",
           %{original: original} do
    check all(
            ids <- StreamData.uniq_list_of(vm_id(), min_length: 1, max_length: 6),
            max_runs: 40
          ) do
      tmp = Path.join(System.tmp_dir!(), "hyper-pin-#{System.unique_integer([:positive])}")
      with_work_dir(original, tmp)
      dir = Hyper.Cfg.Dirs.socket_dir()
      File.mkdir_p!(dir)

      named =
        Enum.flat_map(ids, fn id ->
          [Jailer.host_socket(id), Jailer.host_vsock(id), Agent.relay_socket_path(id)]
        end)

      look_alikes =
        Enum.flat_map(ids, fn id ->
          [
            "fc-#{id}-api.socket.bak",
            "fc-#{id}-vsock.sock~",
            "fc-#{id}",
            "#{id}-api.socket",
            "fc-#{id}-api.sock",
            "grpc-#{id}.socket"
          ]
        end)
        |> Enum.map(&Path.join(dir, &1))

      for path <- named ++ look_alikes, do: File.write!(path, "")

      try do
        Reclaim.reclaim_sockets()

        assert dir |> File.ls!() |> Enum.map(&Path.join(dir, &1)) |> Enum.sort() ==
                 Enum.sort(look_alikes)
      after
        File.rm_rf!(tmp)
      end
    end
  end
end
