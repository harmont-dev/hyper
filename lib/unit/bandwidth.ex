defmodule Unit.Bandwidth do
  @moduledoc """
  A throughput, stored canonically in bytes per second. Build with `bps/1` or the
  binary-prefix constructors (`kibps/1`, `mibps/1`, `gibps/1`, `tibps/1`); read back
  with `as_bytes_per_sec/1`. Arithmetic (`+`, `-`) and comparison
  (`<`, `>`, `<=`, `>=`) come from `Unit.Operators`.
  """

  @enforce_keys [:bytes_per_sec]
  defstruct [:bytes_per_sec]

  @opaque t :: %__MODULE__{bytes_per_sec: integer()}

  @kib 1024
  @mib 1024 * @kib
  @gib 1024 * @mib
  @tib 1024 * @gib

  @spec bps(integer()) :: t()
  def bps(v), do: %__MODULE__{bytes_per_sec: v}

  @spec kibps(integer()) :: t()
  def kibps(v), do: %__MODULE__{bytes_per_sec: v * @kib}

  @spec mibps(integer()) :: t()
  def mibps(v), do: %__MODULE__{bytes_per_sec: v * @mib}

  @spec gibps(integer()) :: t()
  def gibps(v), do: %__MODULE__{bytes_per_sec: v * @gib}

  @spec tibps(integer()) :: t()
  def tibps(v), do: %__MODULE__{bytes_per_sec: v * @tib}

  @spec as_bytes_per_sec(t()) :: integer()
  def as_bytes_per_sec(%__MODULE__{bytes_per_sec: bps}), do: bps

  @doc "The zero throughput (additive identity)."
  @spec zero() :: t()
  def zero, do: %__MODULE__{bytes_per_sec: 0}
end

defimpl Unit.Quantity, for: Unit.Bandwidth do
  def value(q), do: Unit.Bandwidth.as_bytes_per_sec(q)
  def with_value(_q, n), do: Unit.Bandwidth.bps(n)
end
