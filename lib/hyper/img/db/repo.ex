defmodule Hyper.Img.Db.Repo do
  @moduledoc """
  Runtime facade over the active image-graph repository.

  All application code talks to this module; it forwards Ecto callbacks to
  whichever concrete repo `Hyper.Img.Db.Backend` selects (Postgres or
  SQLite). Adapter-specific behaviour is encapsulated in `with_low_priority/2`.
  """

  alias Hyper.Img.Db.Backend

  # --- Ecto.Repo callbacks used across the codebase ------------------------
  # If `grep -rn "Repo\\." lib/` surfaces a callback not listed here, add a
  # matching forwarder. Each is a one-line delegation to the active repo.

  def all(queryable, opts \\ []), do: Backend.repo().all(queryable, opts)
  def one(queryable, opts \\ []), do: Backend.repo().one(queryable, opts)
  def one!(queryable, opts \\ []), do: Backend.repo().one!(queryable, opts)
  def get(queryable, id, opts \\ []), do: Backend.repo().get(queryable, id, opts)
  def get!(queryable, id, opts \\ []), do: Backend.repo().get!(queryable, id, opts)
  def get_by(queryable, clauses, opts \\ []), do: Backend.repo().get_by(queryable, clauses, opts)

  def get_by!(queryable, clauses, opts \\ []),
    do: Backend.repo().get_by!(queryable, clauses, opts)

  def exists?(queryable, opts \\ []), do: Backend.repo().exists?(queryable, opts)
  def insert(struct, opts \\ []), do: Backend.repo().insert(struct, opts)
  def insert!(struct, opts \\ []), do: Backend.repo().insert!(struct, opts)

  def insert_all(schema, entries, opts \\ []),
    do: Backend.repo().insert_all(schema, entries, opts)

  def update(struct, opts \\ []), do: Backend.repo().update(struct, opts)
  def update!(struct, opts \\ []), do: Backend.repo().update!(struct, opts)

  def update_all(queryable, updates, opts \\ []),
    do: Backend.repo().update_all(queryable, updates, opts)

  def delete(struct, opts \\ []), do: Backend.repo().delete(struct, opts)
  def delete!(struct, opts \\ []), do: Backend.repo().delete!(struct, opts)
  def delete_all(queryable, opts \\ []), do: Backend.repo().delete_all(queryable, opts)
  def preload(structs, preloads, opts \\ []), do: Backend.repo().preload(structs, preloads, opts)
  def transaction(fun_or_multi, opts \\ []), do: Backend.repo().transaction(fun_or_multi, opts)
  def rollback(value), do: Backend.repo().rollback(value)
  def query(sql, params \\ [], opts \\ []), do: Backend.repo().query(sql, params, opts)
  def query!(sql, params \\ [], opts \\ []), do: Backend.repo().query!(sql, params, opts)

  @doc """
  Runs `fun` under a best-effort, time-bounded, low-priority context.

  Postgres: wraps `fun` in a transaction with a transaction-local
  `statement_timeout`, so a slow sweep cannot pin a connection indefinitely.
  SQLite: single-writer with a connection `busy_timeout`; there is no
  per-statement timeout, so `fun` is run directly.

  Returns the value of `fun`.
  """
  @spec with_low_priority(non_neg_integer(), (-> result)) :: result when result: var
  def with_low_priority(timeout_ms, fun) when is_integer(timeout_ms) and is_function(fun, 0) do
    case Backend.selected() do
      :postgres ->
        {:ok, result} =
          Backend.repo().transaction(fn ->
            _ =
              Backend.repo().query!("SELECT set_config('statement_timeout', $1, true)", [
                Integer.to_string(timeout_ms)
              ])

            fun.()
          end)

        result

      :sqlite ->
        fun.()
    end
  end
end
