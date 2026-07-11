defmodule Hyper.Grpc.PagePropertiesTest do
  @moduledoc """
  Laws under test for keyset pagination over the VM listing:

    * Termination + reconstruction -- following `next_page_token` from the empty
      cursor until it is empty visits every entry exactly once, in `vm_id` order,
      reproducing the whole set with no duplicates or gaps.
    * Order-independence -- the pages produced do not depend on the order of the
      input list (the registry returns VMs unordered).
    * Size bound -- no page exceeds `min(requested, max)`; a non-positive
      `page_size` uses the default.
    * Token contract -- a malformed `page_token` is rejected with
      `:bad_page_token`, never silently treated as "start".
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Hyper.Grpc.Page

  defp entries do
    gen all(ids <- uniq_list_of(string(:alphanumeric, min_length: 1), max_length: 40)) do
      Enum.map(ids, fn id -> {id, :"node@#{:erlang.phash2(id)}"} end)
    end
  end

  defp collect_all(entries, page_size, token \\ "", acc \\ []) do
    {:ok, {page, next}} = Page.paginate(entries, page_size, token)

    case next do
      "" -> acc ++ page
      _ -> collect_all(entries, page_size, next, acc ++ page)
    end
  end

  property "paging to the end reproduces the whole set, sorted, exactly once" do
    check all(entries <- entries(), page_size <- integer(1..10)) do
      walked = collect_all(entries, page_size)
      assert walked == Enum.sort_by(entries, fn {id, _node} -> id end)
    end
  end

  property "the pages are independent of input order" do
    check all(entries <- entries(), page_size <- integer(1..10)) do
      shuffled = Enum.reverse(entries)
      assert collect_all(entries, page_size) == collect_all(shuffled, page_size)
    end
  end

  property "no page exceeds min(requested, max); non-positive size uses the default" do
    check all(entries <- entries(), page_size <- integer(-5..2000)) do
      {:ok, {page, _next}} = Page.paginate(entries, page_size, "")
      effective = if page_size <= 0, do: 100, else: min(page_size, 1000)
      assert length(page) <= effective
    end
  end

  test "a malformed page_token is rejected, never treated as start" do
    assert {:error, :bad_page_token} = Page.paginate([{"a", :n@h}], 10, "not*valid*base64")
  end
end
