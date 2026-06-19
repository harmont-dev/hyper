defmodule Hyper.Sys.Linux.Losetup do
  @moduledoc "Losetup management utility."

  use OpenTelemetryDecorator

  alias Hyper.Sys.Cmd

  @doc "Attach the given image file read-only as a loop-back block device."
  @spec mount_ro(Path.t()) :: {:ok, Path.t()} | {:error, {non_neg_integer(), String.t()}}
  @decorate with_span("Hyper.Sys.Linux.Losetup.mount_ro", include: [:img_path])
  def mount_ro(img_path) do
    attach(["--read-only", img_path])
  end

  @doc "Attach the given image file read-write as a loop-back block device."
  @spec mount_rw(Path.t()) :: {:ok, Path.t()} | {:error, {non_neg_integer(), String.t()}}
  @decorate with_span("Hyper.Sys.Linux.Losetup.mount_rw", include: [:img_path])
  def mount_rw(img_path) do
    attach([img_path])
  end

  @doc "Detach the given loop block device."
  @spec umount(Path.t()) :: {:ok, Path.t()} | {:error, {non_neg_integer(), String.t()}}
  @decorate with_span("Hyper.Sys.Linux.Losetup.umount", include: [:blk_path])
  def umount(blk_path) do
    case Cmd.run([Hyper.Config.losetup_path(), "-d", blk_path]) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, errc} -> {:error, {errc, out}}
    end
  end

  @spec attach([String.t()]) :: {:ok, Path.t()} | {:error, {non_neg_integer(), String.t()}}
  defp attach(extra_args) do
    case Cmd.run([Hyper.Config.losetup_path(), "--find", "--show"] ++ extra_args) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, errc} -> {:error, {errc, out}}
    end
  end
end
