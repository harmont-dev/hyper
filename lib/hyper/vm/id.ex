defmodule Hyper.Vm.Id do
  @moduledoc """
  A microVM id and its generator.

  An id is a `v` prefix followed by lowercase base32 of 10 random bytes, charset
  `[a-z2-7]` - alphanumeric only, no `-`, `_`, or other punctuation. That charset
  is the intersection of three independent constraints the id must satisfy at
  once:

    * firecracker rejects `_` in an instance id (`InvalidInstanceId`);
    * dm/jailer names must not start with `-`;
    * registry keys and chroot path components stay trivially safe.
  """

  @type t :: String.t()

  @doc """
  Generate a fresh, random VM id (see the module doc for the charset contract).

  The previous base64url encoding emitted `-` and `_`, so it could produce ids
  firecracker refused at boot (`Invalid char (_)`).
  """
  @spec generate() :: t()
  def generate do
    "v" <> Base.encode32(:crypto.strong_rand_bytes(10), padding: false, case: :lower)
  end
end
