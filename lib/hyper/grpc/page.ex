defmodule Hyper.Grpc.Page do
  @moduledoc """
  Keyset pagination over the cluster VM listing. Pure: given the full unordered
  `[{vm_id, node}]` from `Hyper.Cluster.Routing.all/0`, a requested page size,
  and an opaque cursor token, returns one deterministic page plus the token for
  the next page.

  Keyset (cursor-by-`vm_id`), not offset: VMs starting and stopping between calls
  cannot shift a page or skip/duplicate an entry, because the cursor is the last
  `vm_id` seen, not a position. `vm_id`s are unique and totally ordered, so the
  sort is stable across calls. An empty `next_page_token` -- and only that --
  signals end-of-collection (AIP-158).

  Laws are exercised in `test/hyper/grpc/page_properties_test.exs`.
  """

  @default_page_size 100
  @max_page_size 1000

  @type entry :: {Hyper.Vm.Id.t(), node()}

  @doc """
  One page of `entries` after the cursor in `page_token`, plus the next token.

  `page_size <= 0` selects the default (#{@default_page_size}); larger than
  #{@max_page_size} is capped. A `page_token` that is not a token this module
  issued yields `{:error, :bad_page_token}`.
  """
  @spec paginate([entry()], integer(), String.t()) ::
          {:ok, {[entry()], String.t()}} | {:error, :bad_page_token}
  def paginate(entries, page_size, page_token) do
    with {:ok, after_id} <- decode(page_token) do
      remaining =
        entries
        |> Enum.sort_by(fn {vm_id, _node} -> vm_id end)
        |> drop_through(after_id)

      {page, rest} = Enum.split(remaining, clamp(page_size))
      {:ok, {page, next_token(page, rest)}}
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

  @spec clamp(integer()) :: pos_integer()
  defp clamp(size) when size <= 0, do: @default_page_size
  defp clamp(size), do: min(size, @max_page_size)

  @spec drop_through([entry()], binary() | nil) :: [entry()]
  defp drop_through(sorted, nil), do: sorted

  defp drop_through(sorted, after_id),
    do: Enum.drop_while(sorted, fn {vm_id, _node} -> vm_id <= after_id end)

  @spec next_token([entry()], [entry()]) :: String.t()
  defp next_token([], _rest), do: ""
  defp next_token(_page, []), do: ""

  defp next_token(page, _rest) do
    {last_id, _node} = List.last(page)
    encode(last_id)
  end
end
