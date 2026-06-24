defmodule Sys.Linux.Subid do
  @moduledoc "Subuid and Subgid utilities"

  defmodule Spec do
    @moduledoc "A subordinate id range - one `/etc/subuid` or `/etc/subgid` entry."

    @type t :: %__MODULE__{
            name: String.t(),
            min_id: integer(),
            max_id: integer()
          }
    defstruct [:name, :min_id, :max_id]
  end

  @subuid_path "/etc/subuid"
  @subgid_path "/etc/subgid"

  @doc "Return the list of all subuid ranges"
  @spec subuid_ranges ::
          {:ok, [Spec.t()]}
          | {:error, File.posix() | :badarg | :terminated | :system_limit | :invalid_format}
  def subuid_ranges, do: subid_ranges(@subuid_path)

  @doc "Return the list of all subgid ranges"
  @spec subgid_ranges ::
          {:ok, [Spec.t()]}
          | {:error, File.posix() | :badarg | :terminated | :system_limit | :invalid_format}
  def subgid_ranges, do: subid_ranges(@subgid_path)

  @spec subid_ranges(Path.t()) ::
          {:ok, [Spec.t()]}
          | {:error, File.posix() | :badarg | :terminated | :system_limit | :invalid_format}
  defp subid_ranges(path) do
    with {:ok, content} <- File.read(path) do
      content
      |> String.split("\n", trim: true)
      |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
        case parse(line) do
          {:ok, spec} -> {:cont, {:ok, [spec | acc]}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  @doc """
  Parse one `/etc/subuid`/`/etc/subgid` line (`name:start:count`) into a `Spec`,
  where `min_id` is `start` and `max_id` is `start + count`. A line that is not
  exactly three colon-separated fields, or whose start/count are not integers,
  yields `{:error, :invalid_format}`.
  """
  @spec parse(String.t()) :: {:ok, Spec.t()} | {:error, :invalid_format}
  def parse(line) do
    with [name, start_str, count_str] <- String.split(line, ":"),
         {start, ""} <- Integer.parse(start_str),
         {count, ""} <- Integer.parse(count_str) do
      {:ok, %Spec{name: name, min_id: start, max_id: start + count}}
    else
      _ -> {:error, :invalid_format}
    end
  end
end
