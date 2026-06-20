defmodule Hyper.Img.Db.Gc.Sweep do
  @moduledoc """
  Pure accounting core for the layer GC. No processes, no I/O: the shared-medium
  presence probe is injected as a `check_fun`, so a sweep is a deterministic fold
  over `{id, size}` tuples and is unit-tested directly.

  One `t()` accumulates a single full pass over the `blobs` table. `absorb/3`
  classifies a keyset page into present (file on the medium) vs missing (file
  gone) and returns the missing blobs for the GC to prune; `record_prune/4` folds
  the prune outcome back into the tally once the GC has executed it against the
  database.
  """

  defstruct cursor: nil,
            scanned: 0,
            present: 0,
            missing: 0,
            pruned: 0,
            pruned_bytes: 0,
            dangling: 0

  @type t :: %__MODULE__{
          cursor: String.t() | nil,
          scanned: non_neg_integer(),
          present: non_neg_integer(),
          missing: non_neg_integer(),
          pruned: non_neg_integer(),
          pruned_bytes: non_neg_integer(),
          dangling: non_neg_integer()
        }

  @typedoc "A blob page row: content-addressed id and its DB-recorded byte size."
  @type blob :: {String.t(), non_neg_integer()}

  @typedoc "Injected shared-medium probe: true if the blob's file is present."
  @type check_fun :: (String.t() -> boolean())

  @doc "A fresh sweep: nil cursor (start of table), zeroed counters."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Fold one keyset page into the sweep. Advances `cursor` to the last blob's id
  (so the next page starts after it), counts present vs missing, and returns the
  missing blobs (file absent on the medium) as `{id, size}` for the GC to prune.
  """
  @spec absorb(t(), [blob()], check_fun()) :: {t(), [blob()]}
  def absorb(%__MODULE__{} = sweep, batch, check_fun) do
    {sweep, missing_rev} =
      Enum.reduce(batch, {sweep, []}, fn {id, _size} = blob, {acc, missing} ->
        acc = %{acc | scanned: acc.scanned + 1, cursor: id}

        if check_fun.(id) do
          {%{acc | present: acc.present + 1}, missing}
        else
          {%{acc | missing: acc.missing + 1}, [blob | missing]}
        end
      end)

    {sweep, Enum.reverse(missing_rev)}
  end

  @doc """
  Fold the result of pruning one page back into the sweep: `pruned` rows deleted
  totalling `pruned_bytes`, and `dangling` rows left in place (file gone but the
  blob is still referenced by an image - a data-loss condition the GC reports but
  must not delete).
  """
  @spec record_prune(t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) :: t()
  def record_prune(%__MODULE__{} = sweep, pruned, pruned_bytes, dangling) do
    %{
      sweep
      | pruned: sweep.pruned + pruned,
        pruned_bytes: sweep.pruned_bytes + pruned_bytes,
        dangling: sweep.dangling + dangling
    }
  end

  @doc "Full page (`length == limit`) means more rows may remain; page again."
  @spec continue?([term()], pos_integer()) :: boolean()
  def continue?(batch, limit) when is_integer(limit) and limit > 0,
    do: length(batch) == limit
end
