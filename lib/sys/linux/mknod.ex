defmodule Sys.Linux.Mknod do
  @moduledoc "Stage block-device nodes and files into a VM chroot (via the setuid helper)."

  use OpenTelemetryDecorator

  alias Hyper.SuidHelper

  @doc """
  Create in the chroot a block-device node at `dest` mirroring `device` (a host
  block-device path: `/dev/loopN` or `/dev/mapper/hyper-*`), owned `uid:gid`. The
  helper validates `device` and reads its `major:minor` from the device itself,
  so the caller can never name an arbitrary device.
  """
  @spec block(Path.t(), Path.t(), non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, {non_neg_integer(), String.t()}}
  @decorate with_span("Sys.Linux.Mknod.block", include: [:dest, :device])
  def block(dest, device, uid, gid) do
    # mknod has no underlying binary; SuidHelper.run/3 omits --bin for it.
    case SuidHelper.run("mknod", Hyper.Config.suid_helper(), [
           "--dest",
           dest,
           "--device",
           device,
           "--uid",
           to_string(uid),
           "--gid",
           to_string(gid)
         ]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc "Hardlink-or-copy `src` to `dest` inside a chroot, owned `uid:gid`."
  @spec stage(Path.t(), Path.t(), non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, {non_neg_integer(), String.t()}}
  @decorate with_span("Sys.Linux.Mknod.stage", include: [:src, :dest])
  def stage(src, dest, uid, gid) do
    case SuidHelper.run("stage", Hyper.Config.suid_helper(), [
           "--src",
           src,
           "--dest",
           dest,
           "--uid",
           to_string(uid),
           "--gid",
           to_string(gid)
         ]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end
end
