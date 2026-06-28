defmodule Hyper.Vm.IdTest do
  @moduledoc """
  The charset contract of `Hyper.Vm.Id.generate/0`. The load-bearing invariant is
  the refusal property: a generated id is *always* strictly alphanumeric, so it
  can never carry a char that firecracker (`_`) or dm/jailer names (`-`) reject.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Hyper.Vm.Id

  property "generate/0 produces a `v`-prefixed, strictly alphanumeric id" do
    check all(_ <- StreamData.constant(nil)) do
      id = Id.generate()
      assert id =~ ~r/\A[A-Za-z0-9]+\z/
      assert String.starts_with?(id, "v")
    end
  end
end
