defmodule Hyper.Sys.Linux.Losetup do
  @moduledoc "Losetup management utility."

  use OpenTelemetryDecorator

  @doc "Mount the given image file read-only as a loop-back block device."
  @spec mount_ro(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  @decorate with_span("Hyper.Sys.Linux.Losetup.mount_ro", include: [:img_path])
  def mount_ro(img_path) do
    case System.cmd(Hyper.Config.losetup_path(), ["--find", "--show", "--read-only", img_path],
           stderr_to_stdout: true
         ) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, errc} -> {:error, {errc, out}}
    end
  end

  @doc "Unmount the given block device path."
  @decorate with_span("Hyper.Sys.Linux.Losetup.umount", include: [:blk_path])
  @spec umount(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def umount(blk_path) do
    case System.cmd(Hyper.Config.losetup_path(), ["-d", blk_path], stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, errc} -> {:error, {errc, out}}
    end
  end
end
