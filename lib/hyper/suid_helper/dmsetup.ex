defmodule Hyper.SuidHelper.Dmsetup do
  @moduledoc "device-mapper operations (snapshot / thin), via the setuid helper's `dmsetup` tool."

  use OpenTelemetryDecorator

  alias Hyper.SuidHelper

  @type err :: SuidHelper.err()

  @required_targets ~w(linear snapshot thin thin-pool)

  @doc """
  Create a read-only dm-snapshot device named `name`, layering `cow_dev`
  (exception store) over `origin_dev`. `sectors` is the logical size in 512-byte
  sectors. Returns the `/dev/mapper/<name>` path.
  """
  @spec create_snapshot(String.t(), Path.t(), Path.t(), pos_integer()) ::
          {:ok, Path.t()} | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Dmsetup.create_snapshot", include: [:name])
  def create_snapshot(name, origin, cow_file, sectors) do
    table = snapshot_table(origin, cow_file, sectors, Hyper.Cfg.Img.chunk_sectors())
    with {:ok, dev, _loops} <- create(name, table, ["--readonly"]), do: {:ok, dev}
  end

  @spec create_linear(String.t(), Path.t(), pos_integer()) :: {:ok, Path.t()} | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Dmsetup.create_linear", include: [:name])
  def create_linear(name, origin, sectors) do
    with {:ok, dev, _loops} <- create(name, linear_table(origin, sectors), ["--readonly"]),
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
    table = thin_pool_table(meta_file, data_file, sectors, block_sectors, low_water)

    with {:ok, dev, %{"metadata" => meta_loop}} <- create(name, table, []),
         do: {:ok, dev, meta_loop}
  end

  @doc """
  Create a dm-thin volume `name` of `sectors` from thin device id `dev_id` in
  `pool_dev`, with `origin_dev` as its read-only external origin. Returns
  `/dev/mapper/<name>`.
  """
  @spec create_thin_external(String.t(), Path.t(), non_neg_integer(), pos_integer(), Path.t()) ::
          {:ok, Path.t()} | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Dmsetup.create_thin_external", include: [:name])
  def create_thin_external(name, pool_dev, dev_id, sectors, origin_dev) do
    table = thin_external_table(pool_dev, dev_id, sectors, origin_dev)
    with {:ok, dev, _loops} <- create(name, table, []), do: {:ok, dev}
  end

  @doc "Remove the dm device `name`."
  @spec remove(String.t()) :: :ok | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Dmsetup.remove", include: [:name])
  def remove(name) do
    case SuidHelper.exec(["dmsetup", "remove", "--retry", name]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc "Suspend dm device `name`, flushing queued I/O. Pair with `resume/1`."
  @spec suspend(String.t()) :: :ok | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Dmsetup.suspend", include: [:name])
  def suspend(name) do
    case SuidHelper.exec(["dmsetup", "suspend", name]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc "Resume the suspended dm device `name`."
  @spec resume(String.t()) :: :ok | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Dmsetup.resume", include: [:name])
  def resume(name) do
    case SuidHelper.exec(["dmsetup", "resume", name]) do
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
    table = snapshot_table(origin_dev, cow_file, sectors, Hyper.Cfg.Img.chunk_sectors())
    with {:ok, dev, _loops} <- create(name, table, []), do: {:ok, dev}
  end

  @doc "Send a thin-pool `message` to dm device `name`."
  @spec message(String.t(), String.t()) :: :ok | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Dmsetup.message", include: [:name, :message])
  def message(name, message) do
    case SuidHelper.exec(["dmsetup", "message", name, "--message", message]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Verify the kernel exposes the dm targets we use (snapshot, thin, thin-pool).

  Routes through the setuid helper: `dmsetup targets` opens `/dev/mapper/control`,
  which needs root, and the BEAM runs unprivileged. The helper validates its
  configured `dmsetup` binary before running it, so a missing or unsafe binary
  surfaces here too.
  """
  @spec test_system() :: :ok | {:error, term()}
  @decorate with_span("Hyper.SuidHelper.Dmsetup.test_system")
  def test_system do
    case SuidHelper.exec(["dmsetup", "targets"]) do
      {:ok, %{"output" => out}} ->
        have = parse_targets(out)
        missing = Enum.reject(@required_targets, &MapSet.member?(have, &1))
        if missing == [], do: :ok, else: {:error, {:missing_dm_targets, missing}}

      {:error, {code, msg}} ->
        {:error, {:dmsetup_targets_failed, code, msg}}
    end
  end

  @doc false
  @spec parse_targets(String.t()) :: MapSet.t(String.t())
  def parse_targets(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.map(&(&1 |> String.split() |> List.first()))
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  @doc "Names of every device-mapper device currently present on this host."
  @spec list() :: {:ok, [String.t()]} | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Dmsetup.list")
  def list do
    case SuidHelper.exec(["dmsetup", "ls"]) do
      {:ok, %{"output" => out}} -> {:ok, parse_names(out)}
      {:error, _} = err -> err
    end
  end

  @doc false
  @spec parse_names(String.t()) :: [String.t()]
  def parse_names(out) do
    case String.trim(out) do
      # `dmsetup ls` prints this sentinel (not a device row) when there are none.
      "No devices found" ->
        []

      _ ->
        out
        |> String.split("\n", trim: true)
        |> Enum.map(&(&1 |> String.split() |> List.first()))
        |> Enum.reject(&is_nil/1)
    end
  end

  @doc false
  @spec linear_table(Path.t(), pos_integer()) :: String.t()
  def linear_table(origin, sectors) do
    "0 #{sectors} linear #{origin} 0"
  end

  @doc false
  @spec snapshot_table(Path.t(), Path.t(), pos_integer(), pos_integer()) :: String.t()
  def snapshot_table(origin, cow_file, sectors, chunk_sectors) do
    "0 #{sectors} snapshot #{origin} #{cow_file} P #{chunk_sectors}"
  end

  @doc false
  @spec thin_pool_table(Path.t(), Path.t(), pos_integer(), pos_integer(), non_neg_integer()) ::
          String.t()
  def thin_pool_table(meta_file, data_file, sectors, block_sectors, low_water) do
    "0 #{sectors} thin-pool #{meta_file} #{data_file} #{block_sectors} #{low_water}"
  end

  @doc false
  @spec thin_external_table(Path.t(), non_neg_integer(), pos_integer(), Path.t()) :: String.t()
  def thin_external_table(pool_dev, dev_id, sectors, origin_dev) do
    "0 #{sectors} thin #{pool_dev} #{dev_id} #{origin_dev}"
  end

  # Create a dm device named `name` from a reconstructed `table`, with any extra
  # create flags (e.g. `--readonly`). Returns the `/dev/mapper/<name>` path.
  @spec create(String.t(), String.t(), [String.t()]) ::
          {:ok, Path.t(), %{String.t() => Path.t()}} | {:error, err()}
  defp create(name, table, flags) do
    argv = ["dmsetup", "create", name] ++ flags ++ ["--table", table]

    case SuidHelper.exec(argv) do
      {:ok, %{"device" => dev, "loops" => loops}} -> {:ok, dev, loops}
      {:error, _} = err -> err
    end
  end
end
