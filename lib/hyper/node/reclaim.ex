defmodule Hyper.Node.Reclaim do
  @moduledoc """
  Boot-time reclamation of device-mapper and loop devices orphaned by an unclean
  shutdown (SIGKILL or `:erlang.halt`, where the owning GenServers' `terminate/2`
  never ran to tear them down).

  Hyper names every dm device it creates with a `hyper-` prefix (`hyper-thinpool`,
  `hyper-rw-<vm>`, `hyper-img-<img>-<n>`), so this removes exactly those - never an
  operator's unrelated dm devices. Removal is leaf-first: a device still open by
  another (the pool under a thin volume, a snapshot under the next in its chain)
  refuses until its dependents are gone, so leftovers are retried until a pass
  removes nothing new. Loop devices backing files under Hyper's data dirs are then
  detached (the dm devices that held them are gone by that point).

  Entirely best-effort: every failure is logged and boot continues. It runs once,
  before any device-owning GenServer starts, so the freshly-booting node never
  collides with its own previous instance's leftovers.
  """

  alias Hyper.SuidHelper.{Dmsetup, Losetup}

  require Logger

  @dm_prefix "hyper-"

  @spec run() :: :ok
  def run do
    reclaim_dm()
    reclaim_loops()
    reclaim_sockets()
    :ok
  end

  # Exposed with @doc false so tests can invoke it with an isolated socket_dir
  # (via Hyper.Cfg.Toml.put_cache/1) without also exercising the dm/loop paths
  # that require the privileged suid helper.
  @doc false
  @spec reclaim_sockets() :: :ok
  def reclaim_sockets do
    dir = Hyper.Cfg.Dirs.socket_dir()
    # Ensure the dir exists: the relay bind needs it, and the sweep is a no-op
    # on a fresh node where it was never created.
    File.mkdir_p!(dir)

    case File.ls(dir) do
      {:ok, names} ->
        for name <- names,
            String.starts_with?(name, "grpc-") and String.ends_with?(name, ".sock") do
          path = Path.join(dir, name)

          case File.rm(path) do
            :ok ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "reclaim: could not remove stale relay socket #{path}: #{inspect(reason)}"
              )
          end
        end

        :ok

      {:error, reason} ->
        Logger.warning("reclaim: could not list socket dir #{dir}: #{inspect(reason)}")
        :ok
    end
  end

  defp reclaim_dm do
    case Dmsetup.list() do
      {:ok, names} ->
        case Enum.filter(names, &String.starts_with?(&1, @dm_prefix)) do
          [] ->
            :ok

          stale ->
            Logger.warning(
              "reclaim: removing #{length(stale)} stale dm device(s): #{inspect(stale)}"
            )

            remove_dm(stale)
        end

      {:error, reason} ->
        Logger.warning("reclaim: could not list dm devices: #{inspect(reason)}")
    end
  end

  @spec remove_dm([String.t()]) :: :ok
  defp remove_dm([]), do: :ok

  defp remove_dm(names) do
    {failed, removed_any?} =
      Enum.reduce(names, {[], false}, fn name, {failed, any?} ->
        case Dmsetup.remove(name) do
          :ok -> {failed, true}
          {:error, _} -> {[name | failed], any?}
        end
      end)

    cond do
      failed == [] -> :ok
      # A pass made progress: a retry may now clear the devices that were still
      # held by the ones just removed.
      removed_any? -> remove_dm(failed)
      true -> Logger.error("reclaim: could not remove dm devices: #{inspect(failed)}")
    end
  end

  defp reclaim_loops do
    case Losetup.list() do
      {:ok, pairs} ->
        for {dev, backing} <- pairs, under_data_dirs?(backing) do
          case Losetup.detach(dev) do
            :ok ->
              :ok

            {:error, reason} ->
              Logger.warning("reclaim: could not detach #{dev} (#{backing}): #{inspect(reason)}")
          end
        end

        :ok

      {:error, reason} ->
        Logger.warning("reclaim: could not list loop devices: #{inspect(reason)}")
    end
  end

  @spec under_data_dirs?(Path.t()) :: boolean()
  defp under_data_dirs?(path) do
    String.starts_with?(path, Hyper.Cfg.Dirs.scratch_dir() <> "/") or
      String.starts_with?(path, Hyper.Cfg.Dirs.layer_dir() <> "/")
  end
end
