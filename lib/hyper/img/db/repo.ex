defmodule Hyper.Img.Db.Repo do
  @moduledoc """
  Global database of all known layers, and how they relate to each other.

  Tracks images and how they relate (images can build on top of images), and
  answers:
    - Given an image id, is it a base image or a layered image?
    - If an image is a layered image, what are the layers to build it?
    - Who is currently actively holding onto an image (or any of its children)?

  The backend (PostgreSQL or SQLite) is chosen by `Hyper.Img.Db.Config`; see
  that module to configure it.
  """

  use Ecto.Repo,
    otp_app: :hyper,
    adapter: Hyper.Img.Db.Config.adapter()

  @doc """
  Runs `fun` time-bounded and low-priority where the backend supports it.

  Postgres: wraps `fun` in a transaction with a transaction-local
  `statement_timeout`, so a slow sweep cannot pin a connection indefinitely.
  SQLite: single-writer with a connection `busy_timeout` and no per-statement
  timeout, so `fun` is run directly.

  Returns the value of `fun`.
  """
  @spec with_low_priority(non_neg_integer(), (-> result)) :: result when result: var
  def with_low_priority(timeout_ms, fun) when is_integer(timeout_ms) and is_function(fun, 0) do
    if Hyper.Img.Db.Config.sqlite?() do
      fun.()
    else
      {:ok, result} =
        transaction(fn ->
          _ =
            query!("SELECT set_config('statement_timeout', $1, true)", [
              Integer.to_string(timeout_ms)
            ])

          fun.()
        end)

      result
    end
  end
end
