defmodule Hyper.Img.OciLoader do
  @moduledoc """
  Builds an ext4 rootfs from an OCI image and hands it to `Hyper.Img.create/2`.

  `load/1` takes a registry reference (e.g. `"docker.io/library/alpine:3.19"`)
  and:

    1. **pulls** it with `skopeo`, selecting the manifest entry matching this node's
       architecture, into a local OCI layout.
    2. **flattens** it with `umoci unpack`, which applies OCI whiteouts/opaque dirs correctly,
       yielding a merged rootfs directory.
    3. **builds** an ext4 image of that rootfs with `mke2fs -d`.
    4. hands the ext4 file to `Hyper.Img.create/2`, which content-addresses it,
       publishes it into the media store, and records it as a base image --
       returning the `img_id`.

  This module owns only the OCI-to-ext4 conversion; ingesting a prepared image
  file into the store and database is `Hyper.Img`'s job.
  """

  alias Hyper.Config
  alias Hyper.Img.OciLoader.Umoci

  require Logger

  @mib 1024 * 1024

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
    Logger.info("oci: loading image #{ref}")

    case do_load(ref, opts) do
      {:ok, id} = ok ->
        Logger.info("oci: loaded #{ref} as image #{id}")
        ok

      {:error, reason} = err ->
        Logger.warning("oci: failed to load #{ref}: #{inspect(reason)}")
        err
    end
  end

  @spec do_load(String.t(), keyword()) :: {:ok, Hyper.Img.id()} | {:error, term()}
  defp do_load(ref, opts) do
    label = Keyword.get(opts, :label, ref)

    with {:ok, source} <- source(ref),
         :ok <- Umoci.ensure_installed(),
         :ok <- test_system(),
         {:ok, arch} <- Sys.Arch.current() do
      Sys.Tmp.with_tempdir("hyper-oci", fn tmp ->
        with {:ok, rootfs} <- pull_and_unpack(source, goarch(arch), tmp),
             {:ok, content} <- dir_bytes(rootfs),
             bytes = ext4_bytes(content),
             {:ok, staged} <- build_ext4(rootfs, bytes) do
          Hyper.Img.create(staged, label: label)
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
    tools = [
      {"skopeo", Config.skopeo_path()},
      {"umoci", Umoci.bin()},
      {"mke2fs", Config.mke2fs_path()}
    ]

    missing = for {name, path} <- tools, System.find_executable(path) == nil, do: name

    if missing == [], do: :ok, else: {:error, {:missing_tools, missing}}
  end

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

  # `skopeo copy` into a local OCI layout, then `umoci unpack` into a bundle.
  # Returns the path to the flattened rootfs directory.
  @spec pull_and_unpack(String.t(), String.t(), Path.t()) ::
          {:ok, Path.t()} | {:error, term()}
  defp pull_and_unpack(source, goarch, tmp) do
    Logger.debug("oci: pulling and flattening #{source}")
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
         :ok <- tag(cmd(Umoci.bin(), ["unpack", "--image", "#{oci}:img", bundle]), :umoci) do
      {:ok, Path.join(bundle, "rootfs")}
    end
  end

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
    Logger.debug("oci: building #{div(bytes, @mib)} MiB ext4 rootfs")
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

  # Run `bin` with `args`, no shell (System.cmd takes an arg list), merging
  # stderr so failures carry diagnostics. Returns `{output, exit_status}`.
  @spec cmd(Path.t(), [String.t()]) :: {String.t(), non_neg_integer()}
  defp cmd(bin, args), do: System.cmd(bin, args, stderr_to_stdout: true)

  # Tag a command result: `:ok` on exit 0, else `{:error, {<tool>_failed, status, output}}`.
  @spec tag({String.t(), non_neg_integer()}, atom()) :: :ok | {:error, term()}
  defp tag({_out, 0}, _tool), do: :ok
  defp tag({out, status}, tool), do: {:error, {:"#{tool}_failed", status, out}}
end
