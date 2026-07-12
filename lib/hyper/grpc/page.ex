defmodule Hyper.Grpc.Page do
  @moduledoc """
  Generic keyset pagination over an in-memory collection. Pure: given the full
  unordered list of resources, a requested page size, an opaque cursor token,
  and a `Hyper.Grpc.Pageable` module describing how a resource is ordered,
  returns one deterministic page plus the token for the next page.

  Keyset (cursor-by-`Pageable.cursor/1`), not offset: elements appearing or
  disappearing between calls cannot shift a page or skip/duplicate an entry,
  because the cursor is the last key seen, not a position. Cursors are unique and
  totally ordered as binaries, so the sort is stable across calls. An empty
  `next_page_token` -- and only that -- signals end-of-collection (AIP-158).

  Invariants are exercised in `test/hyper/grpc/page_properties_test.exs`.
  """

  @type resource :: term()

  @doc """
  One page of `entries` after the cursor in `page_token`, plus the next token.

  `pageable` is a module implementing `Hyper.Grpc.Pageable`; its `cursor/1`
  orders the collection and its `default_page_size/0` / `max_page_size/0` bound
  the page size. `page_size <= 0` selects the default; larger than the max is
  capped. A `page_token` that is not a token this module issued yields
  `{:error, :bad_page_token}`.
  """
  @spec paginate([resource()], integer(), String.t(), module()) ::
          {:ok, {[resource()], String.t()}} | {:error, :bad_page_token}
  def paginate(entries, page_size, page_token, pageable) do
    with {:ok, after_id} <- decode(page_token) do
      remaining =
        entries
        |> Enum.sort_by(&pageable.cursor/1)
        |> drop_through(after_id, pageable)

      {page, rest} = Enum.split(remaining, clamp(page_size, pageable))
      {:ok, {page, next_token(page, rest, pageable)}}
    end
  end

  @spec decode(String.t()) :: {:ok, binary() | nil} | {:error, :bad_page_token}
  defp decode(""), do: {:ok, nil}

  defp decode(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :bad_page_token}
    end
  end

  @spec encode(binary()) :: String.t()
  defp encode(id), do: Base.url_encode64(id, padding: false)

  @spec clamp(integer(), module()) :: pos_integer()
  defp clamp(size, pageable) when size <= 0, do: pageable.default_page_size()
  defp clamp(size, pageable), do: min(size, pageable.max_page_size())

  @spec drop_through([resource()], binary() | nil, module()) :: [resource()]
  defp drop_through(sorted, nil, _pageable), do: sorted

  defp drop_through(sorted, after_id, pageable),
    do: Enum.drop_while(sorted, fn e -> pageable.cursor(e) <= after_id end)

  @spec next_token([resource()], [resource()], module()) :: String.t()
  defp next_token([], _rest, _pageable), do: ""
  defp next_token(_page, [], _pageable), do: ""

  defp next_token(page, _rest, pageable),
    do: encode(pageable.cursor(List.last(page)))
end
