defmodule Hyper.Node.Img.Publish do
  @moduledoc """
  Materialize a running VM's disk divergence as a new immutable delta layer.

  Pipeline: take a temp thin snapshot of the VM's mutable volume (instant;
  parent resumes immediately) → build a writable dm-snapshot over the VM's
  composed RO image device, backed by a fresh sparse COW file → copy the
  snapshot's provisioned ranges (read from the pool metadata — with an
  external origin they are exactly the divergence) into it, so exactly the
  divergent chunks land in the COW exception store → tear the devices down
  (flushing the store) → ingest the COW file via `Hyper.Img.create_derived/3`.

  The result is a `kind: :delta` blob any node can stack with
  `Dmsetup.create_snapshot/4` — the same format `Img.Server.build_chain/2`
  already composes.
  """

  alias Hyper.Node.Img
  alias Hyper.Node.Img.{Mutable, ThinPool}
  alias Unit.Information

  use OpenTelemetryDecorator
  use Unit.Operators

  # dm-snapshot's persistent exception store records one entry (two
  # little-endian u64 chunk addresses) per exception chunk.
  @exception_entry_bytes 16

  # Store header plus allocation-rounding headroom.
  @cow_slack Information.mib(4)

  @doc """
  Publish `parent_vm_id`'s current rootfs divergence over `parent_img_id`.
  Returns the derived image id. The parent VM keeps running; its I/O pauses
  only for the instant of the thin snapshot.
  """
  @spec fork_image(Hyper.Vm.Id.t(), Hyper.Img.id()) ::
          {:ok, Hyper.Img.id()} | {:error, term()}
  @decorate with_span("Hyper.Node.Img.Publish.fork_image", include: [:parent_vm_id])
  def fork_image(parent_vm_id, parent_img_id) do
    with {:ok, parent} <- lookup_mutable(parent_vm_id),
         :ok <- Mutable.acquire(parent, self()) do
      try do
        materialize(Mutable.describe(parent), parent_img_id)
      after
        _ = Mutable.release(parent)
      end
    end
  end

  @spec lookup_mutable(Hyper.Vm.Id.t()) :: {:ok, pid()} | {:error, term()}
  defp lookup_mutable(vm_id) do
    case Registry.lookup(Img.mutable_registry(), vm_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, {:mutable_not_found, vm_id}}
    end
  end

  @spec materialize(map(), Hyper.Img.id()) :: {:ok, Hyper.Img.id()} | {:error, term()}
  defp materialize(
         %{
           thin_name: origin_name,
           origin_dev: ro_dev,
           img_server: img_server
         },
         img_id
       ) do
    tmp = Hyper.Vm.Id.generate()

    with {:ok, %{dev: snap_dev, id: snap_id}} <-
           ThinPool.snapshot(snap_name(tmp), origin_name, ro_dev) do
      try do
        write_delta(tmp, ro_dev, snap_dev, Img.Server.size(img_server), img_id)
      after
        :ok = ThinPool.destroy(snap_name(tmp), snap_id)
      end
    end
  end

  # Build the writable dm-snapshot, fill its COW store with the divergence, then
  # collapse it back to the plain file and ingest that as the delta layer.
  @spec write_delta(
          String.t(),
          Path.t(),
          Path.t(),
          Information.t(),
          Hyper.Img.id()
        ) ::
          {:ok, Hyper.Img.id()} | {:error, term()}
  defp write_delta(tmp, ro_dev, snap_dev, size, parent_img_id) do
    cow_path = Path.join(Hyper.Cfg.Dirs.scratch_dir(), "fork-delta-#{tmp}.img")

    with :ok <- create_sparse(cow_path, cow_size(size)) do
      try do
        with {:ok, _stats} <- ThinPool.copy_provisioned(snap_dev, ro_dev, cow_path) do
          Hyper.Img.create_derived(parent_img_id, cow_path, label: "fork of #{parent_img_id}")
        end
      after
        # create_derived consumes the file on success and removes it on failure;
        # this only catches aborts before it ran. Never raises on ENOENT.
        _ = File.rm(cow_path)
      end
    end
  end

  # The exception store must hold up to the whole device plus per-chunk
  # metadata; it is sparse, so apparent size costs nothing.
  @spec cow_size(Information.t()) :: Information.t()
  defp cow_size(size) do
    entries = div(Information.as_sectors(size), Hyper.Cfg.Img.chunk_sectors())

    size + Information.bytes(entries * @exception_entry_bytes) +
      @cow_slack
  end

  @spec create_sparse(Path.t(), Information.t()) :: :ok | {:error, term()}
  defp create_sparse(path, size) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, io} <- File.open(path, [:write, :read]) do
      try do
        {:ok, _} = :file.position(io, Information.as_bytes(size))
        :ok = :file.truncate(io)
        :ok
      after
        File.close(io)
      end
    end
  end

  @spec snap_name(String.t()) :: String.t()
  defp snap_name(tmp), do: "hyper-fork-#{tmp}"
end
