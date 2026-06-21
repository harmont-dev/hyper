defmodule Hyper.Img.Db.Gc.Sweep do
  @moduledoc """
  Pure accounting core for the layer GC.

  A `Hyper.Img.Db.Gc.Sweep.State` accumulates a single full pass over the `blobs`
  table. `absorb/3` classifies a keyset page into present (file on the medium) vs
  missing (file gone) and returns the missing blobs for the GC to prune;
  `record_prune/4` folds the prune outcome back into the tally once the GC has
  executed it against the database.
  """

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            cursor: String.t() | nil,
            scanned: non_neg_integer(),
            present: non_neg_integer(),
            missing: non_neg_integer(),
            unknown: non_neg_integer(),
            pruned: non_neg_integer(),
            pruned_bytes: non_neg_integer(),
            dangling: non_neg_integer()
          }

    defstruct cursor: nil,
              scanned: 0,
              present: 0,
              missing: 0,
              unknown: 0,
              pruned: 0,
              pruned_bytes: 0,
              dangling: 0
  end

  @typedoc "A blob page row: content-addressed id and its DB-recorded byte size."
  @type blob :: {String.t(), non_neg_integer()}

  @typedoc """
  Injected shared-medium probe. `:present` = file is there; `:missing` = file is
  genuinely gone (safe to prune); `:unknown` = could not determine (I/O error),
  so the blob is counted but never pruned.
  """
  @type presence :: :present | :missing | :unknown
  @type check_fun :: (String.t() -> presence())

  @doc "A fresh sweep state: nil cursor (start of table), zeroed counters."
  @spec new() :: State.t()
  def new, do: %State{}

  @doc """
  Fold one keyset page into the sweep. Advances `cursor` to the last blob's id
  (so the next page starts after it), counts present / missing / unknown, and
  returns only the genuinely-missing blobs (file confirmed absent) as `{id, size}`
  for the GC to prune. `:unknown` rows (probe I/O error) are counted but never
  returned, so an unreachable medium can never drive a delete.
  """
  @spec absorb(State.t(), [blob()], check_fun()) :: {State.t(), [blob()]}
  def absorb(%State{} = sweep, batch, check_fun) do
    {sweep, missing_rev} =
      Enum.reduce(batch, {sweep, []}, fn {id, _size} = blob, {acc, missing} ->
        acc = %{acc | scanned: acc.scanned + 1, cursor: id}

        case check_fun.(id) do
          :present -> {%{acc | present: acc.present + 1}, missing}
          :missing -> {%{acc | missing: acc.missing + 1}, [blob | missing]}
          :unknown -> {%{acc | unknown: acc.unknown + 1}, missing}
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
  @spec record_prune(State.t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          State.t()
  def record_prune(%State{} = sweep, pruned, pruned_bytes, dangling) do
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
