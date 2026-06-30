defmodule Hyper.SuidHelper.Dmsetup do
  @moduledoc "device-mapper operations (snapshot / thin), via the setuid helper's `dmsetup` tool."

  use OpenTelemetryDecorator

  alias Hyper.SuidHelper

  @type err :: SuidHelper.err()

  @required_targets ~w(snapshot thin thin-pool)

  @doc """
  Create a read-only dm-snapshot device named `name`, layering `cow_dev`
  (exception store) over `origin_dev`. `sectors` is the logical size in 512-byte
  sectors. Returns the `/dev/mapper/<name>` path.
  """
  @spec create_snapshot(String.t(), Path.t(), Path.t(), pos_integer()) ::
          {:ok, Path.t()} | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Dmsetup.create_snapshot", include: [:name])
  def create_snapshot(name, origin_dev, cow_dev, sectors) do
    table = snapshot_table(origin_dev, cow_dev, sectors, Hyper.Cfg.Img.chunk_sectors())
    create(name, table, ["--readonly"])
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
        ) :: {:ok, Path.t()} | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Dmsetup.create_thin_pool", include: [:name])
  def create_thin_pool(name, meta_dev, data_dev, sectors, block_sectors, low_water) do
    table = thin_pool_table(meta_dev, data_dev, sectors, block_sectors, low_water)
    create(name, table, [])
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
    create(name, table, [])
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

  @doc "Names of the existing dm devices."
  @spec list() :: {:ok, [String.t()]} | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Dmsetup.list")
  def list do
    case SuidHelper.exec(["dmsetup", "--bin", Hyper.Cfg.Tools.dmsetup(), "ls"]) do
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
  @spec snapshot_table(Path.t(), Path.t(), pos_integer(), pos_integer()) :: String.t()
  def snapshot_table(origin_dev, cow_dev, sectors, chunk_sectors) do
    "0 #{sectors} snapshot #{origin_dev} #{cow_dev} P #{chunk_sectors}"
  end

  @doc false
  @spec thin_pool_table(Path.t(), Path.t(), pos_integer(), pos_integer(), non_neg_integer()) ::
          String.t()
  def thin_pool_table(meta_dev, data_dev, sectors, block_sectors, low_water) do
    "0 #{sectors} thin-pool #{meta_dev} #{data_dev} #{block_sectors} #{low_water}"
  end

  @doc false
  @spec thin_external_table(Path.t(), non_neg_integer(), pos_integer(), Path.t()) :: String.t()
  def thin_external_table(pool_dev, dev_id, sectors, origin_dev) do
    "0 #{sectors} thin #{pool_dev} #{dev_id} #{origin_dev}"
  end

  # Create a dm device named `name` from a reconstructed `table`, with any extra
  # create flags (e.g. `--readonly`). Returns the `/dev/mapper/<name>` path.
  @spec create(String.t(), String.t(), [String.t()]) :: {:ok, Path.t()} | {:error, err()}
  defp create(name, table, flags) do
    argv = ["dmsetup", "create", name] ++ flags ++ ["--table", table]

    case SuidHelper.exec(argv) do
      {:ok, %{"device" => dev}} -> {:ok, dev}
      {:error, _} = err -> err
    end
  end
end
