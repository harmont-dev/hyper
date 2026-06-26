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

  @units %{"Bps" => 1, "KiBps" => @kib, "MiBps" => @mib, "GiBps" => @gib, "TiBps" => @tib}

  @doc "Parse a string like `\"1GiBps\"`. Suffixes: Bps/KiBps/MiBps/GiBps/TiBps."
  @spec parse(String.t()) :: {:ok, t()} | {:error, {:bad_unit, String.t()}}
  def parse(s) when is_binary(s) do
    case Regex.run(~r/^\s*(\d+)\s*(Bps|KiBps|MiBps|GiBps|TiBps)\s*$/, s) do
      [_, n, suffix] -> {:ok, %__MODULE__{bytes_per_sec: String.to_integer(n) * Map.fetch!(@units, suffix)}}
      _ -> {:error, {:bad_unit, s}}
    end
  end

  @doc "Like `parse/1` but raises `ArgumentError` on bad input."
  @spec parse!(String.t()) :: t()
  def parse!(s) do
    case parse(s) do
      {:ok, v} -> v
      {:error, _} -> raise ArgumentError, "invalid Bandwidth string: #{inspect(s)}"
    end
  end
end

defimpl Unit.Quantity, for: Unit.Bandwidth do
  def value(q), do: Unit.Bandwidth.as_bytes_per_sec(q)
  def with_value(_q, n), do: Unit.Bandwidth.bps(n)
end
