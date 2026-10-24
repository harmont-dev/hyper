defmodule Num.Int do
  @moduledoc "Strict integer parsing."

  @doc """
  Parse a string of ASCII decimal digits into a non-negative integer. Unlike
  `Integer.parse/1`, a leading `+`/`-` and any trailing input are rejected.
  """
  @spec parse_unsigned(String.t()) :: {:ok, non_neg_integer()} | :error
  def parse_unsigned(<<digit, _::binary>> = str) when digit in ?0..?9 do
    case Integer.parse(str) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  def parse_unsigned(_), do: :error
end
