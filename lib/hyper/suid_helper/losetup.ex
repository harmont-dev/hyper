defmodule Hyper.SuidHelper.Losetup do
  @moduledoc "Loop-device operations, via the setuid helper's `losetup` tool."

  use OpenTelemetryDecorator

  alias Hyper.SuidHelper

  @type err :: SuidHelper.err()

  @doc "Attach `path` as a read-only loop-back block device."
  @spec attach_ro(Path.t()) :: {:ok, Path.t()} | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Losetup.attach_ro", include: [:path])
  def attach_ro(path) do
    case SuidHelper.exec(["losetup", "--bin", Hyper.Cfg.Tools.losetup(), "attach", path]) do
      {:ok, %{"device" => dev}} -> {:ok, dev}
      {:error, _} = err -> err
    end
  end

  @doc "Attach `path` as a read-write loop-back block device."
  @spec attach_rw(Path.t()) :: {:ok, Path.t()} | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Losetup.attach_rw", include: [:path])
  def attach_rw(path) do
    case SuidHelper.exec([
           "losetup",
           "--bin",
           Hyper.Cfg.Tools.losetup(),
           "attach",
           "--rw",
           path
         ]) do
      {:ok, %{"device" => dev}} -> {:ok, dev}
      {:error, _} = err -> err
    end
  end

  @doc "Detach the loop block device at `dev`."
  @spec detach(Path.t()) :: :ok | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Losetup.detach", include: [:dev])
  def detach(dev) do
    case SuidHelper.exec(["losetup", "--bin", Hyper.Cfg.Tools.losetup(), "detach", dev]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc "Currently-attached loop devices as `{device, backing_file}` pairs."
  @spec list() :: {:ok, [{Path.t(), Path.t()}]} | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Losetup.list")
  def list do
    case SuidHelper.exec(["losetup", "--bin", Hyper.Cfg.Tools.losetup(), "list"]) do
      {:ok, %{"output" => out}} -> {:ok, parse_list(out)}
      {:error, _} = err -> err
    end
  end

  @doc false
  @spec parse_list(String.t()) :: [{Path.t(), Path.t()}]
  def parse_list(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      # `NAME BACK-FILE` rows; a loop with no backing file has only one column
      # (nothing for us to reclaim by file), so skip it.
      case String.split(line, " ", parts: 2, trim: true) do
        [dev, backing] -> [{dev, String.trim(backing)}]
        _ -> []
      end
    end)
  end

  @doc "Check the losetup binary is present."
  @spec test_system() :: :ok | {:error, :losetup_not_found}
  @decorate with_span("Hyper.SuidHelper.Losetup.test_system")
  def test_system do
    if System.find_executable(Hyper.Cfg.Tools.losetup()),
      do: :ok,
      else: {:error, :losetup_not_found}
  end
end
