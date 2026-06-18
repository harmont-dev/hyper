defmodule Hyper.Node.BlobSource do
  @moduledoc """
  Behaviour for the truth tier — where content-addressed artifacts (base images,
  snapshots) durably live and are fetched from. Implementations will include S3,
  NFS, and desync. Interface only; no implementation yet.
  """

  @typedoc "A logical image reference, e.g. \"ubuntu:22.04\"."
  @type ref :: String.t()

  @typedoc "A content hash addressing an immutable blob, e.g. \"sha256:abc...\"."
  @type hash :: String.t()

  @doc "Resolve a logical ref to the content hash it currently points at."
  @callback resolve(ref()) :: {:ok, hash()} | {:error, term()}

  @doc "Download the blob `hash` into the local file `dest`."
  @callback fetch(hash(), dest :: Path.t()) :: :ok | {:error, term()}

  @doc "Upload local file `src` as a content-addressed blob; returns its hash."
  @callback put(src :: Path.t()) :: {:ok, hash()} | {:error, term()}
end
