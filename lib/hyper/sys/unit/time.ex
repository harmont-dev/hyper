defmodule Hyper.Sys.Unit.Time do
  @moduledoc """
  A duration, stored canonically in nanoseconds. Build with `ns/1`/`us/1`/`ms/1`/`s/1`,
  read back with the matching `as_*` accessor. A `Time` is a distinct struct, so it
  cannot be mixed with other dimensions (`Information`, `Bandwidth`).
  """

  @enforce_keys [:ns]
  defstruct [:ns]

  @opaque t :: %__MODULE__{ns: integer()}

  @us 1_000
  @ms 1_000_000
  @s 1_000_000_000

  @spec ns(integer()) :: t()
  def ns(v), do: %__MODULE__{ns: v}

  @spec us(integer()) :: t()
  def us(v), do: %__MODULE__{ns: v * @us}

  @spec ms(integer()) :: t()
  def ms(v), do: %__MODULE__{ns: v * @ms}

  @spec s(integer()) :: t()
  def s(v), do: %__MODULE__{ns: v * @s}

  @spec as_ns(t()) :: integer()
  def as_ns(%__MODULE__{ns: ns}), do: ns

  @spec as_us(t()) :: integer()
  def as_us(%__MODULE__{ns: ns}), do: div(ns, @us)

  @spec as_ms(t()) :: integer()
  def as_ms(%__MODULE__{ns: ns}), do: div(ns, @ms)

  @spec as_s(t()) :: integer()
  def as_s(%__MODULE__{ns: ns}), do: div(ns, @s)
end
