defmodule Hyper.Node.WorkDir.Plan do
  @moduledoc false

  import Bitwise

  @group_other 0o077
  @permission_bits 0o7777

  @type kind :: :dir | :data
  @type mode :: non_neg_integer()
  @type entry :: {Path.t(), kind(), File.Stat.t()}
  @type change :: {Path.t(), from :: mode(), to :: mode()}
  @type refusal ::
          {:not_a_directory, Path.t()}
          | {:not_owned, Path.t(), owner :: non_neg_integer(), mode()}

  @spec plan([entry()], non_neg_integer()) :: {:ok, [change()]} | {:error, refusal()}
  def plan(entries, uid) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, changes} ->
      case change(entry, uid) do
        :keep -> {:cont, {:ok, changes}}
        {:chmod, change} -> {:cont, {:ok, [change | changes]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> then(fn
      {:ok, changes} -> {:ok, Enum.reverse(changes)}
      {:error, _} = err -> err
    end)
  end

  @spec change(entry(), non_neg_integer()) :: :keep | {:chmod, change()} | {:error, refusal()}
  defp change({path, :dir, %File.Stat{type: type}}, _uid) when type != :directory,
    do: {:error, {:not_a_directory, path}}

  defp change({path, _kind, %File.Stat{mode: mode, uid: owner}}, uid) do
    have = band(mode, @permission_bits)

    cond do
      private?(have) -> :keep
      owner == uid -> {:chmod, {path, have, band(have, bnot(@group_other))}}
      true -> {:error, {:not_owned, path, owner, have}}
    end
  end

  @spec private?(mode()) :: boolean()
  defp private?(mode), do: band(mode, @group_other) == 0
end
