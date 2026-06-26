defmodule Unit.Time do
  @moduledoc """
  A duration, stored canonically in nanoseconds. Build with `ns/1`/`us/1`/`ms/1`/`s/1`,
  read back with the matching `as_*` accessor. A `Time` is a distinct struct, so it
  cannot be mixed with other dimensions (`Information`, `Bandwidth`). Arithmetic
  (`+`, `-`) and comparison (`<`, `>`, `<=`, `>=`) come from `Unit.Operators`.
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

  @doc "The zero duration (additive identity)."
  @spec zero() :: t()
  def zero, do: %__MODULE__{ns: 0}

  @units %{
    "ns" => 1,
    "us" => @us,
    "ms" => @ms,
    "s" => @s,
    "m" => 60 * @s,
    "h" => 3600 * @s
  }

  @doc ~s(Parse a duration string like `"60s"`/`"100ms"`/`"1h"`. Suffixes: ns/us/ms/s/m/h.)
  @spec parse(String.t()) :: {:ok, t()} | {:error, {:bad_unit, String.t()}}
  def parse(s) when is_binary(s) do
    case Regex.run(~r/^\s*(\d+)\s*(ns|us|ms|s|m|h)\s*$/, s) do
      [_, n, suffix] -> {:ok, %__MODULE__{ns: String.to_integer(n) * Map.fetch!(@units, suffix)}}
      _ -> {:error, {:bad_unit, s}}
    end
  end

  @doc "Like `parse/1` but raises `ArgumentError` on bad input."
  @spec parse!(String.t()) :: t()
  def parse!(s) do
    case parse(s) do
      {:ok, v} -> v
      {:error, _} -> raise ArgumentError, "invalid Time string: #{inspect(s)}"
    end
  end
end

defimpl Unit.Quantity, for: Unit.Time do
  # Durations are signed, so subtraction may legitimately go negative.
  def value(q), do: Unit.Time.as_ns(q)
  def with_value(_q, n), do: Unit.Time.ns(n)
end
