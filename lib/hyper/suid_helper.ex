defmodule Hyper.SuidHelper do
  @moduledoc """
  Single typed interface to the setuid-root device helper (`hyper-suidhelper`).

  The node runs unprivileged; this module is the only path to the privileged
  `losetup`/`dmsetup`/`blockdev`/`mknod`/`stage` operations. Each public
  function builds the full argv for one operation and shells the configured
  helper, decoding the JSON object it prints on success. The helper validates
  every argument before briefly escalating to root (see `native/suidhelper`).

  Also provides prerequisite checks (`test_system/0`, `test_targets/0`) that
  verify the helper binary and required dm-targets are present before the node
  starts.
  """

  use OpenTelemetryDecorator

  @typedoc "Error tuple: exit code + trimmed stderr/stdout from the helper."
  @type err :: {non_neg_integer(), String.t()}

  @required_targets ~w(snapshot thin thin-pool)

  # ---------------------------------------------------------------------------
  # Private transport
  # ---------------------------------------------------------------------------

  # Run the helper with `argv`. Returns `{:ok, decoded_json}` on exit 0,
  # `{:error, {code, message}}` otherwise.
  @spec exec([String.t()]) :: {:ok, map()} | {:error, err()}
  defp exec(argv) do
    case System.cmd(Hyper.Config.suid_helper(), argv, stderr_to_stdout: true) do
      {out, 0} -> {:ok, Jason.decode!(out)}
      {out, code} -> {:error, {code, String.trim(out)}}
    end
  end

  # ---------------------------------------------------------------------------
  # losetup
  # ---------------------------------------------------------------------------

  @doc "Attach `path` as a read-only loop-back block device."
  @spec losetup_attach_ro(Path.t()) :: {:ok, Path.t()} | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.losetup_attach_ro", include: [:path])
  def losetup_attach_ro(path) do
    case exec(["losetup", "--bin", Hyper.Config.losetup_path(), "attach", path]) do
      {:ok, %{"device" => dev}} -> {:ok, dev}
      {:error, _} = err -> err
    end
  end

  @doc "Attach `path` as a read-write loop-back block device."
  @spec losetup_attach_rw(Path.t()) :: {:ok, Path.t()} | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.losetup_attach_rw", include: [:path])
  def losetup_attach_rw(path) do
    case exec(["losetup", "--bin", Hyper.Config.losetup_path(), "attach", "--rw", path]) do
      {:ok, %{"device" => dev}} -> {:ok, dev}
      {:error, _} = err -> err
    end
  end

  @doc "Detach the loop block device at `dev`."
  @spec losetup_detach(Path.t()) :: :ok | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.losetup_detach", include: [:dev])
  def losetup_detach(dev) do
    case exec(["losetup", "--bin", Hyper.Config.losetup_path(), "detach", dev]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  # ---------------------------------------------------------------------------
  # dmsetup
  # ---------------------------------------------------------------------------

  @doc """
  Create a read-only dm-snapshot device named `name`, layering `cow_dev`
  (exception store) over `origin_dev`. `sectors` is the logical size in
  512-byte sectors. Returns the `/dev/mapper/<name>` path.
  """
  @spec dmsetup_create_snapshot(String.t(), Path.t(), Path.t(), pos_integer()) ::
          {:ok, Path.t()} | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.dmsetup_create_snapshot", include: [:name])
  def dmsetup_create_snapshot(name, origin_dev, cow_dev, sectors) do
    table = "0 #{sectors} snapshot #{origin_dev} #{cow_dev} P #{Hyper.Config.chunk_sectors()}"

    case exec([
           "dmsetup",
           "--bin",
           Hyper.Config.dmsetup_path(),
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

  @doc """
  Create a dm-thin pool `name` backed by `meta_dev` (metadata loop) and
  `data_dev` (data loop). `sectors` is the data device size; `block_sectors`
  the allocation block size; `low_water` the low-water mark in blocks.
  Returns the `/dev/mapper/<name>` path.
  """
  @spec dmsetup_create_thin_pool(
          String.t(),
          Path.t(),
          Path.t(),
          pos_integer(),
          pos_integer(),
          non_neg_integer()
        ) :: {:ok, Path.t()} | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.dmsetup_create_thin_pool", include: [:name])
  def dmsetup_create_thin_pool(name, meta_dev, data_dev, sectors, block_sectors, low_water) do
    table = "0 #{sectors} thin-pool #{meta_dev} #{data_dev} #{block_sectors} #{low_water}"

    case exec([
           "dmsetup",
           "--bin",
           Hyper.Config.dmsetup_path(),
           "create",
           name,
           "--table",
           table
         ]) do
      {:ok, %{"device" => dev}} -> {:ok, dev}
      {:error, _} = err -> err
    end
  end

  @doc """
  Create a dm-thin volume `name` of `sectors` from thin device id `dev_id`
  in `pool_dev`, with `origin_dev` as its read-only external origin.
  Returns `/dev/mapper/<name>`.
  """
  @spec dmsetup_create_thin_external(
          String.t(),
          Path.t(),
          non_neg_integer(),
          pos_integer(),
          Path.t()
        ) :: {:ok, Path.t()} | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.dmsetup_create_thin_external", include: [:name])
  def dmsetup_create_thin_external(name, pool_dev, dev_id, sectors, origin_dev) do
    table = "0 #{sectors} thin #{pool_dev} #{dev_id} #{origin_dev}"

    case exec([
           "dmsetup",
           "--bin",
           Hyper.Config.dmsetup_path(),
           "create",
           name,
           "--table",
           table
         ]) do
      {:ok, %{"device" => dev}} -> {:ok, dev}
      {:error, _} = err -> err
    end
  end

  @doc "Remove the dm device `name`."
  @spec dmsetup_remove(String.t()) :: :ok | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.dmsetup_remove", include: [:name])
  def dmsetup_remove(name) do
    case exec(["dmsetup", "--bin", Hyper.Config.dmsetup_path(), "remove", "--retry", name]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc "Send a thin-pool `message` to dm device `name`."
  @spec dmsetup_message(String.t(), String.t()) :: :ok | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.dmsetup_message", include: [:name, :message])
  def dmsetup_message(name, message) do
    case exec([
           "dmsetup",
           "--bin",
           Hyper.Config.dmsetup_path(),
           "message",
           name,
           "--message",
           message
         ]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  # ---------------------------------------------------------------------------
  # blockdev
  # ---------------------------------------------------------------------------

  @doc "Size of the block device at `path`, in 512-byte sectors."
  @spec device_sectors(Path.t()) :: {:ok, pos_integer()} | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.device_sectors", include: [:path])
  def device_sectors(path) do
    case exec(["blockdev", "--bin", Hyper.Config.blockdev_path(), "--getsz", path]) do
      {:ok, %{"sectors" => n}} -> {:ok, n}
      {:error, _} = err -> err
    end
  end

  # ---------------------------------------------------------------------------
  # Staging (mknod / stage - no --bin)
  # ---------------------------------------------------------------------------

  @doc """
  Create a block-device node at `dest` mirroring `device` (a host block-device
  path), owned `uid:gid`. The helper reads major:minor from the device itself.
  """
  @spec mknod(Path.t(), Path.t(), non_neg_integer(), non_neg_integer()) :: :ok | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.mknod", include: [:dest, :device])
  def mknod(dest, device, uid, gid) do
    case exec([
           "mknod",
           "--dest",
           dest,
           "--device",
           device,
           "--uid",
           to_string(uid),
           "--gid",
           to_string(gid)
         ]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc "Hardlink-or-copy `src` to `dest` inside a chroot, owned `uid:gid`."
  @spec stage(Path.t(), Path.t(), non_neg_integer(), non_neg_integer()) :: :ok | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.stage", include: [:src, :dest])
  def stage(src, dest, uid, gid) do
    case exec([
           "stage",
           "--src",
           src,
           "--dest",
           dest,
           "--uid",
           to_string(uid),
           "--gid",
           to_string(gid)
         ]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Run the helper's `sys-test` subcommand. Returns `{:ok, hyper_base}` where
  `hyper_base` is the work-dir the helper was compiled against.
  """
  @spec sys_test() :: {:ok, Path.t()} | {:error, err()}
  def sys_test do
    case exec(["sys-test"]) do
      {:ok, %{"hyper_base" => base}} -> {:ok, base}
      {:error, _} = err -> err
    end
  end

  # ---------------------------------------------------------------------------
  # Prerequisite checks
  # ---------------------------------------------------------------------------

  @doc """
  Check that the setuid helper and the device-mapper / loop tooling it execs
  are all present on this machine.
  """
  @spec test_system() :: :ok | {:error, term()}
  def test_system do
    cond do
      System.find_executable(Hyper.Config.suid_helper()) == nil ->
        {:error, :suid_helper_not_found}

      System.find_executable(Hyper.Config.dmsetup_path()) == nil ->
        {:error, :dmsetup_not_found}

      System.find_executable(Hyper.Config.blockdev_path()) == nil ->
        {:error, :blockdev_not_found}

      System.find_executable(Hyper.Config.losetup_path()) == nil ->
        {:error, :losetup_not_found}

      true ->
        :ok
    end
  end

  @doc "Verify the kernel exposes the dm targets we use (snapshot, thin, thin-pool)."
  @spec test_targets() :: :ok | {:error, {:missing_dm_targets, [String.t()]}}
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
end
