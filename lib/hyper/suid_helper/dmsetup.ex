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
    table = "0 #{sectors} snapshot #{origin_dev} #{cow_dev} P #{Hyper.Config.chunk_sectors()}"
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
    table = "0 #{sectors} thin-pool #{meta_dev} #{data_dev} #{block_sectors} #{low_water}"
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
    table = "0 #{sectors} thin #{pool_dev} #{dev_id} #{origin_dev}"
    create(name, table, [])
  end

  @doc "Remove the dm device `name`."
  @spec remove(String.t()) :: :ok | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Dmsetup.remove", include: [:name])
  def remove(name) do
    case SuidHelper.exec([
           "dmsetup",
           "--bin",
           Hyper.Config.dmsetup_path(),
           "remove",
           "--retry",
           name
         ]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc "Send a thin-pool `message` to dm device `name`."
  @spec message(String.t(), String.t()) :: :ok | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Dmsetup.message", include: [:name, :message])
  def message(name, message) do
    argv =
      ["dmsetup", "--bin", Hyper.Config.dmsetup_path(), "message", name, "--message", message]

    case SuidHelper.exec(argv) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Check the dmsetup binary is present and the kernel exposes the dm targets we
  use (snapshot, thin, thin-pool).
  """
  @spec test_system() :: :ok | {:error, term()}
  def test_system do
    if System.find_executable(Hyper.Config.dmsetup_path()),
      do: test_targets(),
      else: {:error, :dmsetup_not_found}
  end

  @doc "Verify the kernel exposes the dm targets we use (snapshot, thin, thin-pool)."
  @spec test_targets() :: :ok | {:error, term()}
  def test_targets do
    case System.cmd(Hyper.Config.dmsetup_path(), ["targets"], stderr_to_stdout: true) do
      {out, 0} ->
        have = parse_targets(out)
        missing = Enum.reject(@required_targets, &MapSet.member?(have, &1))
        if missing == [], do: :ok, else: {:error, {:missing_dm_targets, missing}}

      {out, code} ->
        {:error, {:dmsetup_targets_failed, code, String.trim(out)}}
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

  # Create a dm device named `name` from a reconstructed `table`, with any extra
  # create flags (e.g. `--readonly`). Returns the `/dev/mapper/<name>` path.
  @spec create(String.t(), String.t(), [String.t()]) :: {:ok, Path.t()} | {:error, err()}
  defp create(name, table, flags) do
    argv =
      ["dmsetup", "--bin", Hyper.Config.dmsetup_path(), "create", name] ++
        flags ++ ["--table", table]

    case SuidHelper.exec(argv) do
      {:ok, %{"device" => dev}} -> {:ok, dev}
      {:error, _} = err -> err
    end
  end
end
