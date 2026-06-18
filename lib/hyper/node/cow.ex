defmodule Hyper.Node.Cow do
  @moduledoc """
  Behaviour for copy-on-write provisioning of a per-VM writable rootfs from a
  read-only base. Implementations will include reflink (single filesystem) and
  dm-thin (external origin). Interface only; no implementation yet.
  """

  @doc "Whether this mechanism is usable on the current host."
  @callback available?() :: boolean()

  @doc "Create a writable copy-on-write clone of `base` at `dest`."
  @callback clone(base :: Path.t(), dest :: Path.t()) :: :ok | {:error, term()}

  @doc "Tear down a clone previously created at `volume`."
  @callback destroy(volume :: Path.t()) :: :ok | {:error, term()}
end
