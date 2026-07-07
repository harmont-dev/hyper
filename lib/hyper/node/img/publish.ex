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
  alias Hyper.SuidHelper
  alias Unit.Information

  use OpenTelemetryDecorator

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
  defp materialize(%{thin_name: origin_name, thin_id: origin_id, origin_dev: ro_dev}, img_id) do
    tmp = Hyper.Vm.Id.generate()

    with {:ok, sectors} <- SuidHelper.Blockdev.device_sectors(ro_dev),
         {:ok, %{dev: snap_dev, id: snap_id}} <-
           ThinPool.snapshot(snap_name(tmp), origin_name, origin_id, sectors, ro_dev) do
      try do
        write_delta(tmp, ro_dev, {snap_dev, snap_id}, sectors, img_id)
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
          {Path.t(), non_neg_integer()},
          pos_integer(),
          Hyper.Img.id()
        ) ::
          {:ok, Hyper.Img.id()} | {:error, term()}
  defp write_delta(tmp, ro_dev, {snap_dev, snap_id}, sectors, parent_img_id) do
    cow_path = Path.join(Hyper.Cfg.Dirs.scratch_dir(), "fork-delta-#{tmp}.img")

    with :ok <- create_sparse(cow_path, cow_size(sectors)),
         {:ok, cow_loop} <- SuidHelper.Losetup.attach_rw(cow_path) do
      try do
        with {:ok, write_dev} <-
               SuidHelper.Dmsetup.create_snapshot_rw(cow_name(tmp), ro_dev, cow_loop, sectors),
             {:ok, _stats} <- copy_divergence(tmp, snap_dev, snap_id, write_dev),
             # Removing the snapshot device flushes every exception to the store;
             # only then is the COW file complete on disk.
             :ok <- SuidHelper.Dmsetup.remove(cow_name(tmp)),
             :ok <- SuidHelper.Losetup.detach(cow_loop) do
          Hyper.Img.create_derived(parent_img_id, cow_path, label: "fork of #{parent_img_id}")
        else
          {:error, _} = err ->
            _ = SuidHelper.Dmsetup.remove(cow_name(tmp))
            _ = SuidHelper.Losetup.detach(cow_loop)
            err
        end
      after
        # create_derived consumes the file on success and removes it on failure;
        # this only catches aborts before it ran. Never raises on ENOENT.
        _ = File.rm(cow_path)
      end
    end
  end

  # The pool's own metadata is authoritative: with an external origin, the
  # snapshot's provisioned blocks ARE the divergence, so the copy is O(bytes
  # written). No scan fallback — a host that cannot read its pool metadata
  # (thin-provisioning-tools missing/broken) must fail the publish loudly
  # rather than degrade to an O(device) scan.
  @spec copy_divergence(String.t(), Path.t(), non_neg_integer(), Path.t()) ::
          {:ok, %{scanned: non_neg_integer(), written: non_neg_integer()}} | {:error, term()}
  defp copy_divergence(tmp, snap_dev, snap_id, write_dev) do
    with {:ok, spec} <- ThinPool.mappings(snap_id) do
      ranged_copy(tmp, snap_dev, write_dev, spec)
    end
  end

  # The range list rides to the helper as a scratch file: it can be thousands
  # of entries, far past argv limits, and the helper validates it pre-privilege.
  @spec ranged_copy(String.t(), Path.t(), Path.t(), map()) ::
          {:ok, %{scanned: non_neg_integer(), written: non_neg_integer()}} | {:error, term()}
  defp ranged_copy(tmp, snap_dev, write_dev, spec) do
    ranges_path = Path.join(Hyper.Cfg.Dirs.scratch_dir(), "fork-ranges-#{tmp}.json")

    try do
      with :ok <- File.write(ranges_path, Jason.encode!(spec)) do
        SuidHelper.Blockcopy.copy(snap_dev, write_dev, ranges_path)
      end
    after
      _ = File.rm(ranges_path)
    end
  end

  # The exception store must hold up to the whole device plus per-chunk
  # metadata; it is sparse, so apparent size costs nothing.
  @spec cow_size(pos_integer()) :: Information.t()
  defp cow_size(sectors) do
    data = Information.bytes(sectors * 512)
    per_chunk = Information.bytes(div(sectors, Hyper.Cfg.Img.chunk_sectors()) * 16)

    Information.bytes(
      Information.as_bytes(data) + Information.as_bytes(per_chunk) +
        Information.as_bytes(Information.mib(4))
    )
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

  @spec cow_name(String.t()) :: String.t()
  defp cow_name(tmp), do: "hyper-forkcow-#{tmp}"
end
