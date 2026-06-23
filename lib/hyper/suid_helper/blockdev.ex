defmodule Hyper.SuidHelper.Blockdev do
  @moduledoc "Block-device queries, via the setuid helper's `blockdev` tool."

  use OpenTelemetryDecorator

  alias Hyper.SuidHelper

  @type err :: SuidHelper.err()

  @doc "Size of the block device at `path`, in 512-byte sectors."
  @spec device_sectors(Path.t()) :: {:ok, pos_integer()} | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Blockdev.device_sectors", include: [:path])
  def device_sectors(path) do
    case SuidHelper.exec(["blockdev", "--bin", Hyper.Config.blockdev_path(), "--getsz", path]) do
      {:ok, %{"sectors" => n}} -> {:ok, n}
      {:error, _} = err -> err
    end
  end

  @doc "Check the blockdev binary is present."
  @spec test_system() :: :ok | {:error, :blockdev_not_found}
  def test_system do
    if System.find_executable(Hyper.Config.blockdev_path()),
      do: :ok,
      else: {:error, :blockdev_not_found}
  end
end
