defmodule Unit.Information do
  @moduledoc """
  A quantity of data, stored canonically in bytes. Build with `bytes/1` or the
  binary-prefix constructors (`kib/1`, `mib/1`, `gib/1`, `tib/1`); read back with
  the matching `as_*` accessor. Arithmetic (`+`, `-`) and comparison
  (`<`, `>`, `<=`, `>=`) come from `Unit.Operators`.
  """

  @enforce_keys [:bytes]
  defstruct [:bytes]

  @opaque t :: %__MODULE__{bytes: non_neg_integer()}

  @kib 1024
  @mib 1024 * @kib
  @gib 1024 * @mib
  @tib 1024 * @gib

  @spec bytes(non_neg_integer()) :: t()
  def bytes(v), do: %__MODULE__{bytes: v}

  @spec kib(non_neg_integer()) :: t()
  def kib(v), do: %__MODULE__{bytes: v * @kib}

  @spec mib(non_neg_integer()) :: t()
  def mib(v), do: %__MODULE__{bytes: v * @mib}

  @spec gib(non_neg_integer()) :: t()
  def gib(v), do: %__MODULE__{bytes: v * @gib}

  @spec tib(non_neg_integer()) :: t()
  def tib(v), do: %__MODULE__{bytes: v * @tib}

  @spec as_bytes(t()) :: non_neg_integer()
  def as_bytes(%__MODULE__{bytes: b}), do: b

  @spec as_mib(t()) :: non_neg_integer()
  def as_mib(%__MODULE__{bytes: b}), do: div(b, @mib)

  @spec as_gib(t()) :: non_neg_integer()
  def as_gib(%__MODULE__{bytes: b}), do: div(b, @gib)

  @doc "The zero quantity (additive identity)."
  @spec zero() :: t()
  def zero, do: %__MODULE__{bytes: 0}
end

defimpl Unit.Quantity, for: Unit.Information do
  # Bytes never go negative, so subtraction past zero clamps (see Unit.Operators).
  def value(q), do: Unit.Information.as_bytes(q)
  def with_value(_q, n), do: Unit.Information.bytes(max(0, n))
end
