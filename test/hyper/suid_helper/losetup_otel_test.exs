defmodule Hyper.SuidHelper.LosetupOtelTest do
  use Hyper.OtelCase

  alias Hyper.SuidHelper.Losetup

  test "test_system/0 emits its span" do
    # Returns :ok or {:error, :losetup_not_found} depending on the host; either
    # way the capability probe must be wrapped in a span.
    assert Losetup.test_system() in [:ok, {:error, :losetup_not_found}]
    assert_receive {:span, span(name: "Hyper.SuidHelper.Losetup.test_system")}, 1_000
  end
end
