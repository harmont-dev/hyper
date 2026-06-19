defmodule Sys.Linux.Proc.NetDev do
  @moduledoc """
  Reads cumulative per-interface traffic from `/proc/net/dev`.

  Each data line is `iface: <rx fields…> <tx fields…>` where the first receive
  field is `bytes` and the ninth field overall (the first transmit field) is also
  `bytes`. `total/1` sums rx+tx across every interface except loopback (`lo`),
  which is not real node bandwidth.
  """

  @path "/proc/net/dev"

  # Within the post-colon fields (0-based): rx bytes, then 8 rx fields, then tx bytes.
  @rx_bytes_idx 0
  @tx_bytes_idx 8

  @doc "Read `/proc/net/dev` and total non-loopback bytes."
  @spec read_total() :: {:ok, non_neg_integer()} | {:error, File.posix()}
  def read_total do
    with {:ok, content} <- File.read(@path), do: {:ok, total(content)}
  end

  @doc "Map each interface to its cumulative (rx + tx) bytes."
  @spec parse(String.t()) :: %{String.t() => non_neg_integer()}
  def parse(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, ":", parts: 2) do
        [left, right] ->
          fields = String.split(right)

          if length(fields) > @tx_bytes_idx do
            rx = String.to_integer(Enum.at(fields, @rx_bytes_idx))
            tx = String.to_integer(Enum.at(fields, @tx_bytes_idx))
            [{String.trim(left), rx + tx}]
          else
            []
          end

        _ ->
          []
      end
    end)
    |> Map.new()
  end

  @doc "Total cumulative bytes across all interfaces except loopback."
  @spec total(String.t()) :: non_neg_integer()
  def total(content) do
    content
    |> parse()
    |> Enum.reject(fn {iface, _bytes} -> iface == "lo" end)
    |> Enum.map(fn {_iface, bytes} -> bytes end)
    |> Enum.sum()
  end
end
