defmodule Hyper.Firecracker.Api.Codec do
  @moduledoc """
  Compile-time JSON codec injected into every generated schema via the
  generator's `schema_use` option.

  `oapi_generator` emits each schema's struct and its `__fields__/1` type
  metadata, but no code that moves data on or off the wire. This macro fills
  both directions at compile time, so each schema carries its own conversion:

    * encode -- a `Jason.Encoder` implementation that omits unset (`nil`) and
      internal (`:__info__`) fields, because Firecracker rejects some explicit
      nulls and absent optionals must simply not be sent.
    * decode -- a `decode/1` specialized from the schema's `__fields__/1` (read
      via `@before_compile`, since the function can't be called during its own
      module's compilation). Field casts are baked in: nested schemas and lists
      dispatch to their own generated `decode/1`, everything else passes through.
      No runtime type reflection.
  """

  defmacro __using__(_opts) do
    quote do
      @before_compile Hyper.Firecracker.Api.Codec

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

  defmacro __before_compile__(env) do
    specs =
      env.module
      |> fetch_fields()
      |> Enum.map(fn {key, type} ->
        quote do: {unquote(key), unquote(Atom.to_string(key)), unquote(caster(type))}
      end)

    quote do
      @doc "Build a `#{inspect(__MODULE__)}` from a decoded-JSON map. Compile-time generated."
      @spec decode(term()) :: t() | nil | term()
      def decode(nil), do: nil

      def decode(data) when is_map(data) do
        attrs =
          Enum.reduce([unquote_splicing(specs)], %{}, fn {key, json_key, cast}, acc ->
            case Map.fetch(data, json_key) do
              {:ok, raw} -> Map.put(acc, key, cast.(raw))
              :error -> acc
            end
          end)

        struct(__MODULE__, attrs)
      end

      def decode(other), do: other
    end
  end

  # Read the literal `__fields__(:t)` keyword list from the still-compiling
  # module. The body is pure literal data (atoms, tuples, fully-qualified module
  # aliases), so evaluating it is side-effect-free and does not load the
  # referenced modules.
  @spec fetch_fields(module()) :: keyword()
  defp fetch_fields(module) do
    {:v1, _kind, _meta, clauses} = Module.get_definition(module, {:__fields__, 1})
    {_meta, _args, _guards, body} = Enum.find(clauses, fn {_m, args, _g, _b} -> args == [:t] end)
    {fields, _binding} = Code.eval_quoted(body)
    fields
  end

  # Build the runtime cast for one field type, as quoted AST.
  # `{Mod, :t}` -> the nested schema's own decode; `[inner]` -> map decode over
  # the list; anything else (primitives, enums, lists of primitives) -> identity.
  @spec caster(term()) :: Macro.t()
  defp caster({mod, :t}) when is_atom(mod), do: quote(do: &unquote(mod).decode/1)

  defp caster([{mod, :t}]) when is_atom(mod) do
    quote do
      fn list -> if is_list(list), do: Enum.map(list, &unquote(mod).decode/1), else: list end
    end
  end

  defp caster(_primitive), do: quote(do: &Function.identity/1)
end
