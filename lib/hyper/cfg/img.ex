defmodule Hyper.Cfg.Img do
  @moduledoc """
  This node's image storage configuration: the device-mapper geometry behind the
  read-only layer chain (dm-snapshot) and the per-VM writable layers (dm-thin).

    * `chunk_sectors` - dm-snapshot exception-store chunk size.
    * `thin_block_sectors` - dm-thin pool allocation block size.
    * `thin_pool_data_size` / `thin_pool_meta_size` - sparse sizes of the node's
      dm-thin pool backing devices.
    * `store` - absolute path to the read-only layer store.
  """

  import Hyper.Cfg, only: [get_cfg: 1]

  @chunk_sectors Application.compile_env(:hyper, :chunk_sectors, 8)
  @thin_block_sectors Application.compile_env(:hyper, :thin_block_sectors, 128)

  @doc """
  dm-snapshot exception-store chunk size, in 512-byte sectors (8 = 4 KiB).
  Standardised repo-wide; deltas must be created with this chunk size.
  """
  @spec chunk_sectors :: pos_integer()
  def chunk_sectors, do: @chunk_sectors

  @doc "dm-thin pool data block size, in 512-byte sectors (128 = 64 KiB)."
  @spec thin_block_sectors :: pos_integer()
  def thin_block_sectors, do: @thin_block_sectors

  @doc "Sparse size of the node's dm-thin pool data device."
  @spec thin_pool_data_size :: Unit.Information.t()
  def thin_pool_data_size, do: Unit.Information.gib(64)

  @doc "Sparse size of the node's dm-thin pool metadata device."
  @spec thin_pool_meta_size :: Unit.Information.t()
  def thin_pool_meta_size, do: Unit.Information.gib(1)

  @doc """
  Absolute path to the read-only layer store. config.exs (`store:`) > `[img] store`
  toml > `<work_dir>/layers`.
  """
  @spec store :: Path.t()
  def store,
    do:
      get_cfg(
        runtime: {__MODULE__, :store},
        toml: "img.store",
        default: Path.join(Hyper.Cfg.Dirs.work_dir(), "layers")
      )
end
