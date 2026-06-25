defmodule Hyper.SuidHelper.Losetup do
  @moduledoc "Loop-device operations, via the setuid helper's `losetup` tool."

  use OpenTelemetryDecorator

  alias Hyper.SuidHelper

  @type err :: SuidHelper.err()

  @doc "Attach `path` as a read-only loop-back block device."
  @spec attach_ro(Path.t()) :: {:ok, Path.t()} | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Losetup.attach_ro", include: [:path])
  def attach_ro(path) do
    case SuidHelper.exec(["losetup", "attach", path]) do
      {:ok, %{"device" => dev}} -> {:ok, dev}
      {:error, _} = err -> err
    end
  end

  @doc "Attach `path` as a read-write loop-back block device."
  @spec attach_rw(Path.t()) :: {:ok, Path.t()} | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Losetup.attach_rw", include: [:path])
  def attach_rw(path) do
    case SuidHelper.exec(["losetup", "attach", "--rw", path]) do
      {:ok, %{"device" => dev}} -> {:ok, dev}
      {:error, _} = err -> err
    end
  end

  @doc "Detach the loop block device at `dev`."
  @spec detach(Path.t()) :: :ok | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Losetup.detach", include: [:dev])
  def detach(dev) do
    case SuidHelper.exec(["losetup", "detach", dev]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end
end
