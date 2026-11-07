defmodule Hyper.SuidHelper.Dmsetup do
  @moduledoc "device-mapper operations (snapshot / thin), via the setuid helper's `dmsetup` tool."

  use OpenTelemetryDecorator

  alias Hyper.SuidHelper

  @type err :: SuidHelper.err()

  @doc """
  Create a read-only dm-snapshot device named `name`, layering `cow_dev`
  (exception store) over `origin_dev`. `sectors` is the logical size in 512-byte
  sectors. Returns the `/dev/mapper/<name>` path.
  """
  @spec create_snapshot(String.t(), Path.t(), Path.t(), pos_integer()) ::
          {:ok, Path.t()} | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Dmsetup.create_snapshot", include: [:name])
  def create_snapshot(name, origin, cow_file, sectors) do
    with {:ok, dev, _loops} <-
           create("snapshot", name, sectors, ["--readonly" | snapshot_flags(origin, cow_file)]),
         do: {:ok, dev}
  end

  @spec create_linear(String.t(), Path.t(), pos_integer()) :: {:ok, Path.t()} | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Dmsetup.create_linear", include: [:name])
  def create_linear(name, origin, sectors) do
    with {:ok, dev, _loops} <- create("linear", name, sectors, ["--readonly", "--origin", origin]),
         do: {:ok, dev}
  end

  @doc """
  Create a dm-thin pool `name` backed by `meta_dev` (metadata loop) and
  `data_dev` (data loop). `sectors` is the data device size; `block_sectors` the
  allocation block size; `low_water` the low-water mark in blocks. Returns the
  `/dev/mapper/<name>` path.
  """
  @spec create_thin_pool(
          String.t(),
          Path.t(),
          Path.t(),
          pos_integer(),
          pos_integer(),
          non_neg_integer()
        ) :: {:ok, Path.t(), Path.t()} | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Dmsetup.create_thin_pool", include: [:name])
  def create_thin_pool(name, meta_file, data_file, sectors, block_sectors, low_water) do
    flags = [
      "--metadata",
      meta_file,
      "--data",
      data_file,
      "--block-sectors",
      to_string(block_sectors),
      "--low-water",
      to_string(low_water)
    ]

    with {:ok, dev, %{"metadata" => meta_loop}} <- create("thin-pool", name, sectors, flags),
         do: {:ok, dev, meta_loop}
  end

  @doc """
  Create a dm-thin volume `name` of `sectors` from thin device id `dev_id` in
  `pool_dev`, with `origin_dev` as its read-only external origin. Returns
  `/dev/mapper/<name>`.
  """
  @spec create_thin_external(String.t(), String.t(), non_neg_integer(), pos_integer(), Path.t()) ::
          {:ok, Path.t()} | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Dmsetup.create_thin_external", include: [:name])
  def create_thin_external(name, pool, dev_id, sectors, origin_dev) do
    flags = ["--pool", pool, "--thin-id", to_string(dev_id), "--origin", origin_dev]
    with {:ok, dev, _loops} <- create("thin", name, sectors, flags), do: {:ok, dev}
  end

  @doc "Remove the dm device `name`."
  @spec remove(String.t()) :: :ok | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Dmsetup.remove", include: [:name])
  def remove(name) do
    case SuidHelper.exec(["dm", "remove", "--retry", name]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc "Suspend dm device `name`, flushing queued I/O. Pair with `resume/1`."
  @spec suspend(String.t()) :: :ok | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Dmsetup.suspend", include: [:name])
  def suspend(name) do
    case SuidHelper.exec(["dm", "suspend", name]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc "Resume the suspended dm device `name`."
  @spec resume(String.t()) :: :ok | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Dmsetup.resume", include: [:name])
  def resume(name) do
    case SuidHelper.exec(["dm", "resume", name]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Create a *writable* dm-snapshot device named `name` over `origin_dev`, with
  `cow_dev` as its exception store. Writes to the device land in `cow_dev`,
  which is how a fork's delta layer file is populated. Same table as
  `create_snapshot/4`, minus `--readonly`.
  """
  @spec create_snapshot_rw(String.t(), Path.t(), Path.t(), pos_integer()) ::
          {:ok, Path.t()} | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Dmsetup.create_snapshot_rw", include: [:name])
  def create_snapshot_rw(name, origin_dev, cow_file, sectors) do
    with {:ok, dev, _loops} <-
           create("snapshot", name, sectors, snapshot_flags(origin_dev, cow_file)),
         do: {:ok, dev}
  end

  @doc "Send a thin-pool `message` to dm device `name`."
  @spec message(String.t(), String.t()) :: :ok | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Dmsetup.message", include: [:name, :message])
  def message(name, message) do
    case SuidHelper.exec(["dm", "message", name, "--message", message]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @spec snapshot_flags(Path.t(), Path.t()) :: [String.t()]
  defp snapshot_flags(origin, cow_file) do
    [
      "--origin",
      origin,
      "--cow",
      cow_file,
      "--chunk-sectors",
      to_string(Hyper.Cfg.Img.chunk_sectors())
    ]
  end

  @spec create(String.t(), String.t(), pos_integer(), [String.t()]) ::
          {:ok, Path.t(), %{String.t() => Path.t()}} | {:error, err()}
  defp create(target, name, sectors, flags) do
    argv = ["dm", target, name, "--sectors", to_string(sectors)] ++ flags

    case SuidHelper.exec(argv) do
      {:ok, %{"device" => dev, "loops" => loops}} -> {:ok, dev, loops}
      {:error, _} = err -> err
    end
  end
end
