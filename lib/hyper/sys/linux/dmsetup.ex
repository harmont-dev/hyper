defmodule Hyper.Sys.Linux.Dmsetup do
  @moduledoc "device-mapper (dmsetup) management utility (via the setuid helper)."

  use OpenTelemetryDecorator

  alias Hyper.SuidHelper

  @typedoc "A device-mapper device name (becomes /dev/mapper/<name>)."
  @type name :: String.t()

  @doc "Check that the setuid helper and the device-mapper tooling it execs are present."
  @spec test_system() :: :ok | {:error, term()}
  def test_system do
    cond do
      System.find_executable(Hyper.Config.suid_helper()) == nil -> {:error, :suid_helper_not_found}
      System.find_executable(Hyper.Config.dmsetup_path()) == nil -> {:error, :dmsetup_not_found}
      System.find_executable(Hyper.Config.blockdev_path()) == nil -> {:error, :blockdev_not_found}
      true -> :ok
    end
  end

  @doc """
  Create a read-only dm-snapshot device named `name`, layering `cow_dev`
  (a delta's exception store) over `origin_dev`. `sectors` is the logical size in
  512-byte sectors. Returns the `/dev/mapper/<name>` path.
  """
  @spec create_snapshot(name(), Path.t(), Path.t(), pos_integer()) ::
          {:ok, Path.t()} | {:error, {non_neg_integer(), String.t()}}
  @decorate with_span("Hyper.Sys.Linux.Dmsetup.create_snapshot", include: [:name])
  def create_snapshot(name, origin_dev, cow_dev, sectors) do
    table = "0 #{sectors} snapshot #{origin_dev} #{cow_dev} P #{Hyper.Config.chunk_sectors()}"

    case SuidHelper.run("dmsetup", Hyper.Config.dmsetup_path(), [
           "create",
           name,
           "--readonly",
           "--table",
           table
         ]) do
      {:ok, %{"device" => dev}} -> {:ok, dev}
      {:error, _} = err -> err
    end
  end

  @doc "Remove the dm device `name`."
  @spec remove(name()) :: :ok | {:error, {non_neg_integer(), String.t()}}
  @decorate with_span("Hyper.Sys.Linux.Dmsetup.remove", include: [:name])
  def remove(name) do
    case SuidHelper.run("dmsetup", Hyper.Config.dmsetup_path(), ["remove", "--retry", name]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc "Size of the block device at `path`, in 512-byte sectors."
  @spec device_sectors(Path.t()) ::
          {:ok, pos_integer()} | {:error, {non_neg_integer(), String.t()}}
  @decorate with_span("Hyper.Sys.Linux.Dmsetup.device_sectors", include: [:path])
  def device_sectors(path) do
    case SuidHelper.run("blockdev", Hyper.Config.blockdev_path(), ["--getsz", path]) do
      {:ok, %{"sectors" => sectors}} -> {:ok, sectors}
      {:error, _} = err -> err
    end
  end
end
