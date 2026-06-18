defmodule Hyper.Sys.Unit.Bandwidth do
  @moduledoc """
  A throughput, stored canonically in bytes per second. Build with `bps/1` or the
  binary-prefix constructors (`kibps/1`, `mibps/1`, `gibps/1`, `tibps/1`); read back
  with `as_bytes_per_sec/1`.
  """

  @enforce_keys [:bytes_per_sec]
  defstruct [:bytes_per_sec]

  @opaque t :: %__MODULE__{bytes_per_sec: non_neg_integer()}

  @kib 1024
  @mib 1024 * @kib
  @gib 1024 * @mib
  @tib 1024 * @gib

  @spec bps(non_neg_integer()) :: t()
  def bps(v), do: %__MODULE__{bytes_per_sec: v}

  @spec kibps(non_neg_integer()) :: t()
  def kibps(v), do: %__MODULE__{bytes_per_sec: v * @kib}

  @spec mibps(non_neg_integer()) :: t()
  def mibps(v), do: %__MODULE__{bytes_per_sec: v * @mib}

  @spec gibps(non_neg_integer()) :: t()
  def gibps(v), do: %__MODULE__{bytes_per_sec: v * @gib}

  @spec tibps(non_neg_integer()) :: t()
  def tibps(v), do: %__MODULE__{bytes_per_sec: v * @tib}

  @spec as_bytes_per_sec(t()) :: non_neg_integer()
  def as_bytes_per_sec(%__MODULE__{bytes_per_sec: bps}), do: bps
end
