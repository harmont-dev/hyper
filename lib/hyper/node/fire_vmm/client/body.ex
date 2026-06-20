defmodule Hyper.Node.FireVMM.Client.Body do
  @moduledoc """
  Turns a Firecracker request struct (or raw map) into a JSON-ready map with
  `nil` fields removed. Firecracker rejects some explicit `null`s, so absent
  optional fields must be omitted rather than serialized as null. Recurses
  through nested structs and lists. `false` and `0` are preserved.
  """

  @spec encode(struct() | map()) :: map()
  def encode(%_{} = struct), do: struct |> Map.from_struct() |> compact()
  def encode(map) when is_map(map), do: compact(map)

  @spec compact(map()) :: map()
  defp compact(map) do
    Enum.reduce(map, %{}, fn
      {_k, nil}, acc -> acc
      {k, v}, acc -> Map.put(acc, k, value(v))
    end)
  end

  @spec value(term()) :: term()
  defp value(%_{} = v), do: encode(v)
  defp value(v) when is_list(v), do: Enum.map(v, &value/1)
  defp value(v), do: v
end
