defmodule Hyper.SuidHelper.Jail do
  @moduledoc """
  Privileged chroot/jail staging, via the setuid helper's `mknod` / `stage` /
  `reset-jail` subcommands. These are built into the helper (no external binary),
  so there is no separate `test_system/0` - `Hyper.SuidHelper.test_system/0`
  already checks the helper itself is present.
  """

  use OpenTelemetryDecorator

  alias Hyper.SuidHelper

  @type err :: SuidHelper.err()

  @doc """
  Create a block-device node at `dest` mirroring `device` (a host block-device
  path), owned `uid:gid`. The helper reads major:minor from the device itself.
  """
  @spec mknod(Path.t(), Path.t(), non_neg_integer(), non_neg_integer()) :: :ok | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Jail.mknod", include: [:dest, :device])
  def mknod(dest, device, uid, gid) do
    argv = [
      "mknod",
      "--dest",
      dest,
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

  @doc "Hardlink-or-copy `src` to `dest` inside a chroot, owned `uid:gid`."
  @spec stage(Path.t(), Path.t(), non_neg_integer(), non_neg_integer()) :: :ok | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Jail.stage", include: [:src, :dest])
  def stage(src, dest, uid, gid) do
    argv = [
      "stage",
      "--src",
      src,
      "--dest",
      dest,
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
  @spec reset(Path.t(), Path.t()) :: :ok | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Jail.reset", include: [:chroot, :cgroup])
  def reset(chroot, cgroup) do
    case SuidHelper.exec(["reset-jail", "--chroot", chroot, "--cgroup", cgroup]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end
end
