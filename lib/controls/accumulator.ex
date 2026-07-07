defmodule Controls.Accumulator do
  @moduledoc """
  Accrues consumption from a monotonically increasing cumulative counter,
  tolerating counter resets (the counter's source was destroyed and recreated,
  restarting from zero — e.g. a VM's cgroup across a restart).

    * `observe/2` folds in a cumulative reading: the first reading is a
      baseline; a reading `>=` the previous adds the delta; a reading *below*
      the previous is a reset, and the whole new reading is consumption
      accrued since recreation.
    * `total/1` reads the accrued consumption; `flush/1` zeroes it (call after
      the total has been durably recorded) while keeping the baseline.

  Works on any `Unit.Quantity`. Laws under test: a monotone sequence accrues
  exactly `last - first`; the total is never negative; observing the same
  reading twice adds nothing; interleaved flushes conserve the grand total.
  """

  alias Unit.Quantity

  @enforce_keys [:zero]
  defstruct [:zero, last: nil, accrued: 0]

  @opaque t :: %__MODULE__{zero: Quantity.t(), last: integer() | nil, accrued: integer()}

  @doc "A fresh accumulator. `zero` is the zero quantity of the counter's dimension."
  @spec new(Quantity.t()) :: t()
  def new(zero), do: %__MODULE__{zero: zero}

  @doc "Fold in the latest cumulative reading."
  @spec observe(t(), Quantity.t()) :: t()
  def observe(%__MODULE__{last: nil} = acc, reading),
    do: %{acc | last: Quantity.value(reading)}

  def observe(%__MODULE__{last: last, accrued: accrued} = acc, reading) do
    value = Quantity.value(reading)
    delta = if value >= last, do: value - last, else: value
    %{acc | last: value, accrued: accrued + delta}
  end

  @doc "Consumption accrued since the last `flush/1`."
  @spec total(t()) :: Quantity.t()
  def total(%__MODULE__{zero: zero, accrued: accrued}),
    do: Quantity.with_value(zero, accrued)

  @doc "Zero the accrued consumption, keeping the baseline."
  @spec flush(t()) :: t()
  def flush(%__MODULE__{} = acc), do: %{acc | accrued: 0}
end
