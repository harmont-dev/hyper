defmodule Hyper.SuidHelper.ChrootJail do
  @moduledoc """
  Privileged chroot/jail lifecycle, via the setuid helper's `chroot-jail`
  subcommands (`prepare` / `remove`). These are built into the helper (no
  external binary), so there is no separate `test_system/0` -
  `Hyper.SuidHelper.test_system/0` already checks the helper itself is present.
  """

  use OpenTelemetryDecorator

  alias Hyper.SuidHelper

  @type err :: SuidHelper.err()

  @doc """
  Prepare `chroot_root`'s boot artifacts: stage the `kernel` file in and `mknod`
  a node mirroring the rootfs `device`, both owned `uid:gid`. The helper places
  them at the fixed in-jail names (`/vmlinux`, `/rootfs`) and reads the device's
  major:minor itself.
  """
  @spec prepare(Path.t(), Path.t(), Path.t(), non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.ChrootJail.prepare", include: [:chroot_root, :device])
  def prepare(chroot_root, kernel, device, uid, gid) do
    argv = [
      "chroot-jail",
      "prepare",
      "--chroot",
      chroot_root,
      "--kernel",
      kernel,
      "--device",
      device,
      "--uid",
      to_string(uid),
      "--gid",
      to_string(gid)
    ]

    case SuidHelper.exec(argv) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Remove a VM's stale jail before (re)launch: recursively delete the per-VM
  chroot dir and rmdir its (empty) cgroup leaf. Idempotent - a first boot with no
  prior state is a no-op. The helper confines `chroot` under the jail base and
  `cgroup` under `/sys/fs/cgroup` (see `native/suidhelper`).
  """
  @spec remove(Path.t(), Path.t()) :: :ok | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.ChrootJail.remove", include: [:chroot, :cgroup])
  def remove(chroot, cgroup) do
    case SuidHelper.exec(["chroot-jail", "remove", "--chroot", chroot, "--cgroup", cgroup]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end
end
