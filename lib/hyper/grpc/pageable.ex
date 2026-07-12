defmodule Hyper.Grpc.Pageable do
  @moduledoc """
  Contract a resource must satisfy to be paginated by `Hyper.Grpc.Page`.

  A conforming module declares how one element of a collection is ordered and
  what page sizes are allowed. `Hyper.Grpc.Page` is generic over any such module,
  so a new resource-listing RPC gets AIP-158 keyset pagination by implementing
  this behaviour rather than copying the paginator.

  ## Invariants a conforming module must uphold

    * `cursor/1` returns a **unique** binary for every element in the collection.
      Uniqueness is what makes keyset pagination stable: the page cursor is the
      last key seen, not a position, so elements appearing or disappearing
      between calls cannot shift a page or skip/duplicate an element.
    * The cursor's **lexicographic (byte) order matches the resource's intended
      total order**. `Hyper.Grpc.Page` sorts and compares cursors as binaries.
      A key that is not already an order-preserving binary (e.g. an integer id)
      must be encoded to one here -- zero-padded or fixed-width big-endian -- so
      byte order matches the logical order. Returning, say, `Integer.to_string/1`
      would sort `"10"` before `"2"` and page incorrectly.

  The cursor is a binary (not an arbitrary term) so the page token stays a plain
  `Base.url_encode64` of the cursor and decoding a token never runs the unsafe
  `:erlang.binary_to_term`.
  """

  @doc "A unique, order-preserving binary key for one collection element."
  @callback cursor(resource :: term()) :: binary()

  @doc "Page size used when the request asks for a non-positive size."
  @callback default_page_size() :: pos_integer()

  @doc "Upper bound a requested page size is capped to."
  @callback max_page_size() :: pos_integer()
end
