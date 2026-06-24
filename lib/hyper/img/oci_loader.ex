defmodule Hyper.Img.OciLoader do
  @moduledoc """
  Loads an OCI image into Hyper's media store and image database.

  `load/1` takes a registry reference (e.g. `"docker.io/library/alpine:3.19"`)
  and, end to end:

    1. **pulls** it with `skopeo`, selecting the manifest entry matching this
       node's architecture, into a local OCI layout;
    2. **flattens** it with `umoci unpack`, which applies OCI whiteouts/opaque
       dirs correctly, yielding a merged rootfs directory;
    3. **builds** an ext4 image of that rootfs with `mke2fs -d` (no loopback, no
       privilege, no setuid helper);
    4. **content-addresses** the image by the sha256 of its bytes -- that hash is
       the blob id and the filename stem (`layer_<id>.img`);
    5. **publishes** it into `Hyper.Config.layer_dir/0` via an atomic
       same-filesystem rename, *then* records it as a one-layer base image
       (`blobs` + `images` + `image_layers`) in a single transaction.

  Publish-before-record is deliberate: the layer GC prunes a `blobs` row whose
  file is missing, so a row must never exist before its file. The rename is the
  commit point; the file appears whole or not at all.

  Scope (YAGNI): the loader produces a *faithful* rootfs. It does not synthesise
  an init or read the image's Entrypoint/Cmd -- booting is the caller's job via
  `boot_args` (`root=/dev/vda rw init=<...>`). The content hash is over the
  produced ext4 bytes, which are not byte-reproducible, so re-importing the same
  ref may yield a fresh id; that is accepted.
  """

  alias Hyper.Config
  alias Hyper.Img.Db.{Blob, Image, ImageLayer, Repo}

  @mib 1024 * 1024
  @hash_chunk 2 * @mib

  # ext4 metadata (inode tables, journal, reserved blocks) plus slack so the
  # rootfs always fits. Overhead scales with content -- a flat constant is far
  # too small for large images -- as 25% of content plus an 8 MiB base, never
  # below a 16 MiB floor. The base is a read-only dm-snapshot origin (guest
  # writes land in the COW layer, never here), so generous slack is cheap.
  @base_overhead_bytes 8 * @mib
  @floor_bytes 16 * @mib

  @doc "Load `ref` into the store and DB. See the module doc. Label defaults to `ref`."
  @spec load(String.t()) :: {:ok, Hyper.Img.id()} | {:error, term()}
  def load(ref), do: load(ref, [])

  @doc """
  Load `ref`. `opts[:label]` sets the human-readable `images.label` (defaults to
  `ref`).

  Returns `{:error, {:missing_tools, names}}` when the node lacks a required
  external tool (`skopeo`/`umoci`/`mke2fs`); the check runs up front so the load
  fails fast before the multi-minute pull.
  """
  @spec load(String.t(), keyword()) :: {:ok, Hyper.Img.id()} | {:error, term()}
  def load(ref, opts) when is_binary(ref) and is_list(opts) do
    label = Keyword.get(opts, :label, ref)

    with {:ok, source} <- source(ref),
         :ok <- test_system(),
         {:ok, arch} <- Sys.Arch.current() do
      Sys.Tmp.with_tempdir("hyper-oci", fn tmp ->
        with {:ok, rootfs} <- pull_and_unpack(source, goarch(arch), tmp),
             {:ok, content} <- dir_bytes(rootfs),
             bytes = ext4_bytes(content),
             {:ok, staged} <- build_ext4(rootfs, bytes),
             {:ok, id} <- finalize(staged, bytes, label) do
          {:ok, id}
        end
      end)
    end
  end

  @doc """
  Verify the external tools the loader needs (`skopeo`, `umoci`, `mke2fs`) are
  resolvable on this host. Returns `{:error, {:missing_tools, names}}` listing
  any that are absent.
  """
  @spec test_system() :: :ok | {:error, {:missing_tools, [String.t()]}}
  def test_system do
    missing =
      [Config.skopeo_path(), Config.umoci_path(), Config.mke2fs_path()]
      |> Enum.reject(&System.find_executable/1)

    if missing == [], do: :ok, else: {:error, {:missing_tools, missing}}
  end

  # --- pure derivations (no I/O; the unit-tested core) ----------------------

  # Validate `ref` and return the `skopeo` source `"docker://" <> ref`. A ref must
  # be non-empty and contain no whitespace (refs never do; rejecting whitespace
  # also closes the door on accidental arg-splitting surprises).
  @doc false
  @spec source(String.t()) :: {:ok, String.t()} | {:error, :invalid_ref}
  def source(ref) when is_binary(ref) do
    if ref != "" and not String.match?(ref, ~r/\s/),
      do: {:ok, "docker://" <> ref},
      else: {:error, :invalid_ref}
  end

  # Map a Hyper architecture to the Go/OCI arch name `skopeo --override-arch` wants.
  @doc false
  @spec goarch(Sys.Arch.t()) :: String.t()
  def goarch(:x86_64), do: "amd64"
  def goarch(:aarch64), do: "arm64"

  # ext4 image size (bytes) for a rootfs whose contents total `content_bytes`:
  # content + scaled overhead (25% of content + 8 MiB base), rounded up to a whole
  # MiB, never below 16 MiB.
  @doc false
  @spec ext4_bytes(non_neg_integer()) :: pos_integer()
  def ext4_bytes(content_bytes) when is_integer(content_bytes) and content_bytes >= 0 do
    raw = content_bytes + div(content_bytes, 4) + @base_overhead_bytes
    rounded = div(raw + @mib - 1, @mib) * @mib
    max(rounded, @floor_bytes)
  end

  # --- pull + flatten -------------------------------------------------------

  # `skopeo copy` into a local OCI layout, then `umoci unpack` into a bundle.
  # Returns the path to the flattened rootfs directory.
  @spec pull_and_unpack(String.t(), String.t(), Path.t()) ::
          {:ok, Path.t()} | {:error, term()}
  defp pull_and_unpack(source, goarch, tmp) do
    oci = Path.join(tmp, "oci")
    bundle = Path.join(tmp, "bundle")

    skopeo =
      cmd(Config.skopeo_path(), [
        "copy",
        "--override-os",
        "linux",
        "--override-arch",
        goarch,
        source,
        "oci:#{oci}:img"
      ])

    with :ok <- tag(skopeo, :skopeo),
         :ok <- tag(cmd(Config.umoci_path(), ["unpack", "--image", "#{oci}:img", bundle]), :umoci) do
      {:ok, Path.join(bundle, "rootfs")}
    end
  end

  # --- size + build ---------------------------------------------------------

  # Apparent byte total of the rootfs tree (`du -sb`), parsed from the first field.
  @spec dir_bytes(Path.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  defp dir_bytes(rootfs) do
    case System.cmd("du", ["-sb", rootfs], stderr_to_stdout: true) do
      {out, 0} ->
        case Integer.parse(out) do
          {bytes, _rest} -> {:ok, bytes}
          :error -> {:error, {:du_unparsable, out}}
        end

      {out, status} ->
        {:error, {:du_failed, status, out}}
    end
  end

  # Build an ext4 image of `rootfs` sized to `bytes` (a whole-MiB multiple),
  # staged *inside `layer_dir`* so the later publish is an atomic
  # same-filesystem rename. `mke2fs` creates the file at the given size and
  # populates it from the directory in one rootless step. Returns the staged
  # image path; the staged file is removed if mke2fs fails.
  @spec build_ext4(Path.t(), pos_integer()) :: {:ok, Path.t()} | {:error, term()}
  defp build_ext4(rootfs, bytes) do
    File.mkdir_p!(Config.layer_dir())
    staged = Path.join(Config.layer_dir(), ".incoming-#{System.unique_integer([:positive])}.img")
    size_arg = "#{div(bytes, 1024 * 1024)}M"
    args = ["-t", "ext4", "-F", "-q", "-d", rootfs, staged, size_arg]

    case tag(cmd(Config.mke2fs_path(), args), :mke2fs) do
      :ok ->
        {:ok, staged}

      {:error, _} = err ->
        _ = File.rm(staged)
        err
    end
  end

  # Hash the staged image (its sha256 is the content-addressed id), publish it
  # into the store, then record the base image. If anything fails before the
  # file is published, remove the staged file so a partial build never lingers
  # in the shared store. `bytes` (the mke2fs size) is exactly the file size, so
  # it is the recorded blob size -- no extra stat.
  @spec finalize(Path.t(), pos_integer(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp finalize(staged, bytes, label) do
    with {:ok, id} <- sha256_file(staged),
         {:ok, _final} <- publish_file(staged, id),
         :ok <- record(id, label, bytes) do
      {:ok, id}
    else
      {:error, _} = err ->
        _ = File.rm(staged)
        err
    end
  end

  # --- hash + publish -------------------------------------------------------

  # Streaming sha256 of `path`, lowercase hex.
  @spec sha256_file(Path.t()) :: {:ok, String.t()} | {:error, term()}
  defp sha256_file(path) do
    digest =
      path
      |> File.stream!([:read, :binary, :raw], @hash_chunk)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    {:ok, digest}
  rescue
    e -> {:error, {:hash_failed, Exception.message(e)}}
  end

  # Move the staged image to its content-addressed final path via an atomic
  # rename (same filesystem as `layer_dir`). If the file already exists (same
  # bytes already published), drop the staged copy and reuse it.
  @spec publish_file(Path.t(), String.t()) :: {:ok, Path.t()} | {:error, term()}
  defp publish_file(staged, id) do
    File.mkdir_p!(Config.layer_dir())
    final = final_path(id)

    cond do
      File.exists?(final) ->
        _ = File.rm(staged)
        {:ok, final}

      true ->
        case File.rename(staged, final) do
          :ok -> {:ok, final}
          {:error, reason} -> {:error, {:publish_failed, reason}}
        end
    end
  end

  @spec final_path(String.t()) :: Path.t()
  defp final_path(id), do: Path.join(Config.layer_dir(), "layer_#{id}.img")

  # --- DB record ------------------------------------------------------------

  # Record the base image: one blob, one image (id == blob id), one layer at
  # position 0. All upserts are idempotent so a re-publish of the same bytes is a
  # no-op. The blob is inserted before the layer so the FK is satisfied.
  @spec record(String.t(), String.t(), non_neg_integer()) :: :ok | {:error, term()}
  defp record(id, label, size) do
    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.insert(
        :blob,
        Blob.changeset(%Blob{}, %{id: id, kind: :base, size: size}),
        on_conflict: :nothing,
        conflict_target: :id
      )
      |> Ecto.Multi.insert(
        :image,
        Image.changeset(%Image{}, %{id: id, label: label}),
        on_conflict: :nothing,
        conflict_target: :id
      )
      |> Ecto.Multi.insert(
        :layer,
        ImageLayer.changeset(%ImageLayer{}, %{image_id: id, position: 0, blob_id: id}),
        on_conflict: :nothing,
        conflict_target: [:image_id, :position]
      )

    case Repo.transaction(multi) do
      {:ok, _} -> :ok
      {:error, step, reason, _changes} -> {:error, {:record_failed, step, reason}}
    end
  end

  # --- external-command plumbing -------------------------------------------

  # Run `bin` with `args`, no shell (System.cmd takes an arg list), merging
  # stderr so failures carry diagnostics. Returns `{output, exit_status}`.
  @spec cmd(Path.t(), [String.t()]) :: {String.t(), non_neg_integer()}
  defp cmd(bin, args), do: System.cmd(bin, args, stderr_to_stdout: true)

  # Tag a command result: `:ok` on exit 0, else `{:error, {<tool>_failed, status, output}}`.
  @spec tag({String.t(), non_neg_integer()}, atom()) :: :ok | {:error, term()}
  defp tag({_out, 0}, _tool), do: :ok
  defp tag({out, status}, tool), do: {:error, {:"#{tool}_failed", status, out}}
end
