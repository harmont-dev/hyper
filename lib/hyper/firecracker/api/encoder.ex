defmodule Hyper.Firecracker.Api.Encoder do
  @moduledoc """
  Injected into every generated schema via the generator's `schema_use` option.
  Implements `Jason.Encoder` so request bodies omit `nil` (unset optional) fields
  and the internal `:__info__` bookkeeping field — Firecracker rejects some
  explicit `null`s, so absent options must not be serialized.
  """

  defmacro __using__(_opts) do
    quote do
      defimpl Jason.Encoder do
        def encode(value, opts) do
          value
          |> Map.from_struct()
          |> Map.delete(:__info__)
          |> Enum.reject(fn {_key, v} -> is_nil(v) end)
          |> Map.new()
          |> Jason.Encode.map(opts)
        end
      end
    end
  end
end
