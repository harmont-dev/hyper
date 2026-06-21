defmodule Hyper.Firecracker.Api.Decoder do
  @moduledoc """
  Generic JSON→struct decoder driven by generated schemas' `__fields__/1` type
  metadata. Given a decoded-JSON value and an `oapi_generator` type spec, returns
  the typed value: builds `{module, type}` into the struct, recurses through
  `{:array, t}` and `{:union, types}`, and passes primitives through. Spec-driven,
  so it adapts automatically when schemas are regenerated.
  """

  @spec decode(term(), term()) :: term()
  def decode(nil, _type), do: nil
  def decode(data, :null), do: data
  def decode(data, {:union, types}), do: decode(data, pick(types, data))
  def decode(data, {:array, inner}) when is_list(data), do: Enum.map(data, &decode(&1, inner))

  def decode(data, {module, type}) when is_atom(module) and is_map(data) do
    fields = module.__fields__(type)

    decoded =
      Enum.reduce(fields, %{}, fn {key, field_type}, acc ->
        case Map.fetch(data, Atom.to_string(key)) do
          {:ok, raw} -> Map.put(acc, key, decode(raw, field_type))
          :error -> acc
        end
      end)

    struct(module, decoded)
  end

  def decode(data, _primitive), do: data

  # Union selection is type-based, not value-based: pick the first non-:null
  # member. Safe because Firecracker's spec has only `T | null` unions.
  @spec pick([term()], term()) :: term()
  defp pick(types, _data), do: Enum.find(types, hd(types), &(&1 != :null))
end
