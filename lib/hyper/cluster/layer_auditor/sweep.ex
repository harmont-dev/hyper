defmodule Hyper.Cluster.LayerAuditor.Sweep do
  @moduledoc """
  Pure accounting core for the layer audit. Holds no processes and does no I/O:
  the shared-medium lookup is injected as a `check_fun`, so the whole sweep is a
  deterministic fold over `{id, size}` tuples and is unit-tested directly.

  One `t()` accumulates a single full pass over the `blobs` table; the auditor
  GenServer drives it batch by batch and acts on the returned outcomes.
  """

  @enforce_keys []
  defstruct cursor: nil, scanned: 0, present: 0, missing: 0, mismatch: 0

  @type t :: %__MODULE__{
          cursor: String.t() | nil,
          scanned: non_neg_integer(),
          present: non_neg_integer(),
          missing: non_neg_integer(),
          mismatch: non_neg_integer()
        }

  @typedoc "Per-blob audit result. Mismatch carries expected then actual size."
  @type outcome ::
          :present
          | {:missing, String.t(), non_neg_integer()}
          | {:mismatch, String.t(), non_neg_integer(), non_neg_integer()}

  @typedoc "Injected shared-medium probe: returns the on-medium size, or not_found."
  @type check_fun :: (String.t() -> {:ok, non_neg_integer()} | {:error, :not_found})

  @doc "A fresh sweep with a nil cursor (start of table) and zeroed counters."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Classify one `{id, expected_size}` blob against the shared medium."
  @spec classify({String.t(), non_neg_integer()}, check_fun()) :: outcome()
  def classify({id, expected}, check_fun) do
    case check_fun.(id) do
      {:ok, ^expected} -> :present
      {:ok, actual} -> {:mismatch, id, expected, actual}
      {:error, :not_found} -> {:missing, id, expected}
    end
  end

  @doc """
  Fold one keyset batch into the sweep. Advances `cursor` to the last blob's id
  (so the next page starts after it), bumps the counters, and returns the
  per-blob outcomes in input order for the caller to report on.
  """
  @spec absorb(t(), [{String.t(), non_neg_integer()}], check_fun()) :: {t(), [outcome()]}
  def absorb(%__MODULE__{} = sweep, batch, check_fun) do
    {sweep, outcomes_rev} =
      Enum.reduce(batch, {sweep, []}, fn {id, _size} = blob, {acc, outs} ->
        outcome = classify(blob, check_fun)
        {tally(acc, id, outcome), [outcome | outs]}
      end)

    {sweep, Enum.reverse(outcomes_rev)}
  end

  @doc """
  Was this batch full? A full batch (`length == limit`) means more rows may
  remain, so the auditor pages again; a short or empty batch ends the sweep.
  """
  @spec continue?([term()], pos_integer()) :: boolean()
  def continue?(batch, limit) when is_integer(limit) and limit > 0,
    do: length(batch) == limit

  @spec tally(t(), String.t(), outcome()) :: t()
  defp tally(sweep, id, outcome) do
    sweep = %{sweep | scanned: sweep.scanned + 1, cursor: id}

    case outcome do
      :present -> %{sweep | present: sweep.present + 1}
      {:missing, _, _} -> %{sweep | missing: sweep.missing + 1}
      {:mismatch, _, _, _} -> %{sweep | mismatch: sweep.mismatch + 1}
    end
  end
end
