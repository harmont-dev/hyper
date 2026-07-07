defmodule Sys.Linux.NssTest do
  @moduledoc """
  Live contracts of the NSS lookups (parsing laws live in
  `nss_properties_test.exs`):

    * `Passwd.entries/0` round-trips real `getent passwd` output through the
      parser, and contains root — uid 0 exists on every Linux system;
    * `getent/1` of a database NSS does not know refuses with
      `{:getent_failed, code}` — never a silent empty success.
  """
  use ExUnit.Case, async: true

  alias Sys.Linux.Nss

  test "the live passwd database parses and contains root (uid 0)" do
    assert {:ok, entries} = Nss.Passwd.entries()
    assert Enum.any?(entries, &(&1.uid == 0))
  end

  test "an unknown database is refused with the getent exit code" do
    assert {:error, {:getent_failed, code}} = Nss.getent("hyper-no-such-database")
    assert is_integer(code) and code > 0
  end
end
