defmodule Hyper.Sys.Linux.Dmsetup do
  @moduledoc "device-mapper (dmsetup) management utility."

  use OpenTelemetryDecorator

  alias Hyper.Sys.Cmd

  @typedoc "A device-mapper device name (becomes /dev/mapper/<name>)."
  @type name :: String.t()

  @doc "Check that the device-mapper tooling required for image assembly is present."
  @spec test_system() :: :ok | {:error, term()}
  def test_system do
    cond do
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

    create(name, table, ["--readonly"])
  end

  @doc """
  Create a writable, transient dm-snapshot device named `name`, layering the
  writable `cow_dev` over the read-only `origin_dev`. Used for a VM's ephemeral
  writable layer; exceptions are not persisted across a reboot.
  """
  @spec create_writable(name(), Path.t(), Path.t(), pos_integer()) ::
          {:ok, Path.t()} | {:error, {non_neg_integer(), String.t()}}
  @decorate with_span("Hyper.Sys.Linux.Dmsetup.create_writable", include: [:name])
  def create_writable(name, origin_dev, cow_dev, sectors) do
    table = "0 #{sectors} snapshot #{origin_dev} #{cow_dev} N #{Hyper.Config.chunk_sectors()}"

    create(name, table, [])
  end

  @doc "Remove the dm device `name`."
  @spec remove(name()) :: :ok | {:error, {non_neg_integer(), String.t()}}
  @decorate with_span("Hyper.Sys.Linux.Dmsetup.remove", include: [:name])
  def remove(name) do
    case Cmd.run([Hyper.Config.dmsetup_path(), "remove", "--retry", name]) do
      {_out, 0} -> :ok
      {out, errc} -> {:error, {errc, out}}
    end
  end

  @doc "Size of the block device at `path`, in 512-byte sectors."
  @spec device_sectors(Path.t()) ::
          {:ok, pos_integer()} | {:error, {non_neg_integer(), String.t()}}
  @decorate with_span("Hyper.Sys.Linux.Dmsetup.device_sectors", include: [:path])
  def device_sectors(path) do
    case Cmd.run([Hyper.Config.blockdev_path(), "--getsz", path]) do
      {out, 0} -> {:ok, out |> String.trim() |> String.to_integer()}
      {out, errc} -> {:error, {errc, out}}
    end
  end

  @spec create(name(), String.t(), [String.t()]) ::
          {:ok, Path.t()} | {:error, {non_neg_integer(), String.t()}}
  defp create(name, table, flags) do
    case Cmd.run([Hyper.Config.dmsetup_path(), "create", name] ++ flags ++ ["--table", table]) do
      {_out, 0} -> {:ok, "/dev/mapper/#{name}"}
      {out, errc} -> {:error, {errc, out}}
    end
  end
end
