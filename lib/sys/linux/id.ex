defmodule Sys.Linux.Id do
  @moduledoc "Parsing of the unsigned numeric ids (uid, gid, subid) in Linux id databases."

  @doc """
  Parse a decimal unsigned id. Unlike `Integer.parse/1`, a leading `+`/`-` is
  rejected: ids are never signed, and the conflict checks that consume these
  ranges would silently miss a negative one instead of refusing the line.
  """
  @spec parse(String.t()) :: {:ok, non_neg_integer()} | :error
  def parse(<<digit, _::binary>> = str) when digit in ?0..?9 do
    case Integer.parse(str) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  def parse(_), do: :error
end
