defmodule Hyper.Img.OciLoader.Params do
  @moduledoc """
  Pure derivations for `Hyper.Img.OciLoader`: registry-ref validation, the
  Hyper-arch -> Go/OCI-arch name mapping `skopeo` expects, and the ext4 image
  size for a rootfs of a given content size. No I/O — every function here is a
  total function of its arguments, which is why this is the unit-tested core.
  """

  @mib 1024 * 1024
  # ext4 metadata (inode tables, journal, reserved blocks) plus slack so the
  # rootfs always fits. The base is a read-only dm-snapshot origin -- guest
  # writes land in the COW layer, never here -- so modest headroom is plenty.
  @overhead_bytes 4 * @mib
  @floor_bytes 16 * @mib

  @doc """
  Validate `ref` and return the `skopeo` source `"docker://" <> ref`.

  A ref must be non-empty and contain no whitespace (refs never do; rejecting
  whitespace also closes the door on accidental arg-splitting surprises).
  """
  @spec source(String.t()) :: {:ok, String.t()} | {:error, :invalid_ref}
  def source(ref) when is_binary(ref) do
    if ref != "" and not String.match?(ref, ~r/\s/),
      do: {:ok, "docker://" <> ref},
      else: {:error, :invalid_ref}
  end

  @doc "Map a Hyper architecture to the Go/OCI arch name `skopeo --override-arch` wants."
  @spec goarch(Sys.Arch.t()) :: String.t()
  def goarch(:x86_64), do: "amd64"
  def goarch(:aarch64), do: "arm64"

  @doc """
  ext4 image size (bytes) for a rootfs whose contents total `content_bytes`:
  content + fixed overhead, rounded up to a whole MiB, never below 16 MiB.
  """
  @spec ext4_bytes(non_neg_integer()) :: pos_integer()
  def ext4_bytes(content_bytes) when is_integer(content_bytes) and content_bytes >= 0 do
    raw = content_bytes + @overhead_bytes
    rounded = div(raw + @mib - 1, @mib) * @mib
    max(rounded, @floor_bytes)
  end
end
