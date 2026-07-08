defmodule Unit.Information do
  @moduledoc """
  A quantity of data, stored canonically in bytes. Build with `bytes/1` or the
  binary-prefix constructors (`kib/1`, `mib/1`, `gib/1`, `tib/1`); read back with
  the matching `as_*` accessor. Arithmetic (`+`, `-`) and comparison
  (`<`, `>`, `<=`, `>=`) come from `Unit.Operators`.
  """

  @enforce_keys [:bytes]
  defstruct [:bytes]

  @opaque t :: %__MODULE__{bytes: integer()}

  @kib 1024
  @mib 1024 * @kib
  @gib 1024 * @mib
  @tib 1024 * @gib

  # A disk sector is 512 bytes by kernel convention (dm tables, `blockdev
  # --getsz`, /proc/diskstats), independent of the device's physical sector
  # size.
  @sector 512

  @spec bytes(integer()) :: t()
  def bytes(v), do: %__MODULE__{bytes: v}

  @spec kib(integer()) :: t()
  def kib(v), do: %__MODULE__{bytes: v * @kib}

  @spec mib(integer()) :: t()
  def mib(v), do: %__MODULE__{bytes: v * @mib}

  @spec gib(integer()) :: t()
  def gib(v), do: %__MODULE__{bytes: v * @gib}

  @spec tib(integer()) :: t()
  def tib(v), do: %__MODULE__{bytes: v * @tib}

  @doc "`v` 512-byte disk sectors — the kernel's universal block-device unit."
  @spec sectors(integer()) :: t()
  def sectors(v), do: %__MODULE__{bytes: v * @sector}

  @spec as_bytes(t()) :: integer()
  def as_bytes(%__MODULE__{bytes: b}), do: b

  @spec as_mib(t()) :: integer()
  def as_mib(%__MODULE__{bytes: b}), do: div(b, @mib)

  @spec as_gib(t()) :: integer()
  def as_gib(%__MODULE__{bytes: b}), do: div(b, @gib)

  @doc "The quantity in whole 512-byte sectors."
  @spec as_sectors(t()) :: integer()
  def as_sectors(%__MODULE__{bytes: b}), do: div(b, @sector)

  @doc "The zero quantity (additive identity)."
  @spec zero() :: t()
  def zero, do: %__MODULE__{bytes: 0}

  @units %{"B" => 1, "KiB" => @kib, "MiB" => @mib, "GiB" => @gib, "TiB" => @tib}

  @doc "Parse a string like `\"4GiB\"` into an `Information`. Suffixes: B/KiB/MiB/GiB/TiB."
  @spec parse(String.t()) :: {:ok, t()} | {:error, {:bad_unit, String.t()}}
  def parse(s) when is_binary(s) do
    with {n, suffix} when n >= 0 <- Integer.parse(String.trim(s)),
         {:ok, mult} <- Map.fetch(@units, String.trim(suffix)) do
      {:ok, %__MODULE__{bytes: n * mult}}
    else
      _ -> {:error, {:bad_unit, s}}
    end
  end

  @doc "Like `parse/1` but raises `ArgumentError` on bad input."
  @spec parse!(String.t()) :: t()
  def parse!(s) do
    case parse(s) do
      {:ok, v} -> v
      {:error, _} -> raise ArgumentError, "invalid Information string: #{inspect(s)}"
    end
  end
end

defimpl Unit.Quantity, for: Unit.Information do
  def value(q), do: Unit.Information.as_bytes(q)
  def with_value(_q, n), do: Unit.Information.bytes(n)
end
