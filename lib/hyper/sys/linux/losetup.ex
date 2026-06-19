defmodule Hyper.Sys.Linux.Losetup do
  @moduledoc "Losetup management utility (via the setuid helper)."

  use OpenTelemetryDecorator

  alias Hyper.SuidHelper

  @doc "Attach the given image file read-only as a loop-back block device."
  @spec mount_ro(Path.t()) :: {:ok, Path.t()} | {:error, {non_neg_integer(), String.t()}}
  @decorate with_span("Hyper.Sys.Linux.Losetup.mount_ro", include: [:img_path])
  def mount_ro(img_path) do
    case SuidHelper.run("losetup", Hyper.Config.losetup_path(), ["attach", img_path]) do
      {:ok, %{"device" => dev}} -> {:ok, dev}
      {:error, _} = err -> err
    end
  end

  @doc "Detach the given loop block device."
  @spec umount(Path.t()) :: {:ok, Path.t()} | {:error, {non_neg_integer(), String.t()}}
  @decorate with_span("Hyper.Sys.Linux.Losetup.umount", include: [:blk_path])
  def umount(blk_path) do
    case SuidHelper.run("losetup", Hyper.Config.losetup_path(), ["detach", blk_path]) do
      {:ok, %{"result" => "detached"}} -> {:ok, blk_path}
      {:error, _} = err -> err
    end
  end
end
