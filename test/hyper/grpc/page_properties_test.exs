defmodule Hyper.Grpc.PagePropertiesTest do
  @moduledoc """
  Invariants under test for the generic keyset paginator, exercised against a
  minimal `Hyper.Grpc.Pageable` implementation (`TestResource`) so they hold for
  the behaviour contract itself, not for any one resource:

    * Termination + reconstruction -- following `next_page_token` from the empty
      cursor until it is empty visits every element exactly once, in cursor
      order, reproducing the whole set with no duplicates or gaps.
    * Order-independence -- the pages produced do not depend on the order of the
      input list.
    * Size bound -- no page exceeds `min(requested, max)`; a non-positive
      `page_size` uses the default.
    * Token contract -- a malformed `page_token` is rejected with
      `:bad_page_token`, never silently treated as "start".
    * Cursor threading -- on a fixed, known set, each page's contents and the
      `next_page_token` that leads to the next are exactly what keyset
      pagination by cursor prescribes.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Hyper.Grpc.Page

  defmodule TestResource do
    @moduledoc "Minimal Pageable over `{binary_key, payload}`; default 100 / max 1000."
    @behaviour Hyper.Grpc.Pageable

    @impl true
    def cursor({key, _payload}), do: key

    @impl true
    def default_page_size, do: 100

    @impl true
    def max_page_size, do: 1000
  end

  defp entries do
    gen all(keys <- uniq_list_of(string(:alphanumeric, min_length: 1), max_length: 40)) do
      Enum.map(keys, fn key -> {key, :"payload_#{:erlang.phash2(key)}"} end)
    end
  end

  defp collect_all(entries, page_size, token \\ "", acc \\ []) do
    {:ok, {page, next}} = Page.paginate(entries, page_size, token, TestResource)

    case next do
      "" -> acc ++ page
      _ -> collect_all(entries, page_size, next, acc ++ page)
    end
  end

  property "paging to the end reproduces the whole set, sorted, exactly once" do
    check all(entries <- entries(), page_size <- integer(1..10)) do
      walked = collect_all(entries, page_size)
      assert walked == Enum.sort_by(entries, fn {key, _payload} -> key end)
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
      {:ok, {page, _next}} = Page.paginate(entries, page_size, "", TestResource)
      effective = if page_size <= 0, do: 100, else: min(page_size, 1000)
      assert length(page) <= effective
      assert length(page) == min(effective, length(entries))
    end
  end

  test "a malformed page_token is rejected, never treated as start" do
    assert {:error, :bad_page_token} =
             Page.paginate([{"a", :p}], 10, "not*valid*base64", TestResource)
  end

  test "a known set pages exactly, with the cursor threading correctly" do
    entries = for key <- ~w(e a j c h b f i d g), do: {key, :p}

    assert {:ok, {page1, next1}} = Page.paginate(entries, 3, "", TestResource)
    assert page1 == for(key <- ~w(a b c), do: {key, :p})
    assert next1 == Base.url_encode64("c", padding: false)

    assert {:ok, {page2, next2}} = Page.paginate(entries, 3, next1, TestResource)
    assert page2 == for(key <- ~w(d e f), do: {key, :p})
    assert next2 == Base.url_encode64("f", padding: false)

    assert {:ok, {page3, next3}} = Page.paginate(entries, 3, next2, TestResource)
    assert page3 == for(key <- ~w(g h i), do: {key, :p})
    assert next3 == Base.url_encode64("i", padding: false)

    assert {:ok, {page4, next4}} = Page.paginate(entries, 3, next3, TestResource)
    assert page4 == [{"j", :p}]
    assert next4 == ""
  end
end
