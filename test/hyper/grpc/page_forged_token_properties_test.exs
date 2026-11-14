defmodule Hyper.Grpc.PageForgedTokenPropertiesTest do
  @moduledoc """
  `Hyper.Grpc.Page` under a hostile ListVms caller, who controls both
  `page_token` (any string) and `page_size` (any int32), over the real
  `Hyper.Grpc.Pageable.Vm`.

  Laws:

    * total: no token string and no page size makes `paginate/4` raise — it
      answers a page or `:bad_page_token`;
    * a forged token cannot read outside keyset order: whatever cursor `c` it
      decodes to, the page is exactly the first `min(size, max)` VMs (default
      for a non-positive size) whose id sorts strictly after `c`, so a forged
      cursor neither skips nor re-lists a VM relative to that position;
    * the next token a forged page returns resumes exactly after that page.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Hyper.Grpc.Page
  alias Hyper.Grpc.Pageable.Vm, as: Pageable

  defp vms do
    gen all(
          ids <- uniq_list_of(string(:printable, min_length: 1, max_length: 12), max_length: 60),
          nodes <- list_of(member_of([:a@h, :b@h, :c@h]), length: length(ids))
        ) do
      Enum.zip(ids, nodes)
    end
  end

  defp int32, do: one_of([integer(-5..1_200), member_of([-2_147_483_648, 2_147_483_647])])

  defp effective(size) when size <= 0, do: Pageable.default_page_size()
  defp effective(size), do: min(size, Pageable.max_page_size())

  property "any token string and int32 size answers a page or :bad_page_token, never a raise" do
    check all(
            entries <- vms(),
            size <- int32(),
            token <- one_of([string(:printable), string(:utf8), binary()])
          ) do
      case Page.paginate(entries, size, token, Pageable) do
        {:ok, {page, next}} -> assert is_list(page) and is_binary(next)
        {:error, :bad_page_token} -> :ok
      end
    end
  end

  property "a forged cursor pages exactly the VMs sorting after it, and resumes after the page" do
    check all(entries <- vms(), cursor <- binary(min_length: 1, max_length: 14), size <- int32()) do
      token = Base.url_encode64(cursor, padding: false)
      {:ok, {page, next}} = Page.paginate(entries, size, token, Pageable)

      after_cursor = entries |> Enum.filter(fn {id, _} -> id > cursor end) |> Enum.sort()
      assert page == Enum.take(after_cursor, effective(size))

      case next do
        "" ->
          assert length(after_cursor) <= effective(size)

        _ ->
          {:ok, {following, _}} = Page.paginate(entries, size, next, Pageable)

          assert following ==
                   after_cursor |> Enum.drop(length(page)) |> Enum.take(effective(size))
      end
    end
  end
end
