defmodule Hyper.Firecracker.Api.DecoderTest do
  use ExUnit.Case, async: true

  alias Hyper.Firecracker.Api.Decoder

  defmodule Inner do
    defstruct [:n, :__info__]
    def __fields__(:t), do: [n: :integer]
  end

  defmodule Sample do
    defstruct [:id, :name, :flag, :maybe, :tags, :child, :__info__]

    def __fields__(:t),
      do: [
        id: :integer,
        name: {:string, :generic},
        flag: :boolean,
        maybe: {:union, [{:string, :generic}, :null]},
        tags: {:array, {:string, :generic}},
        child: {:union, [{Inner, :t}, :null]}
      ]
  end

  test "builds a struct, recursing arrays, unions, and nested modules; omits absent keys" do
    data = %{
      "id" => 7,
      "name" => "vm",
      "flag" => false,
      "maybe" => nil,
      "tags" => ["a", "b"],
      "child" => %{"n" => 3}
    }

    assert %Sample{
             id: 7,
             name: "vm",
             flag: false,
             maybe: nil,
             tags: ["a", "b"],
             child: %Inner{n: 3}
           } = Decoder.decode(data, {Sample, :t})
  end

  test "leaves a missing field unset rather than nil-overwriting" do
    assert %Sample{id: 1, name: nil} = Decoder.decode(%{"id" => 1}, {Sample, :t})
  end

  test "passes primitives through and maps :null/nil" do
    assert Decoder.decode(5, :integer) == 5
    assert Decoder.decode(nil, {Sample, :t}) == nil
    assert Decoder.decode([%{"n" => 1}], {:array, {Inner, :t}}) == [%Inner{n: 1}]
  end
end
