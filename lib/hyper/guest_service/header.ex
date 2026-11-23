defmodule Hyper.GuestService.Header do
  @moduledoc false

  @max_bytes 256
  @name ~r/\A[a-z0-9_-]{1,255}\z/

  @spec parse(binary()) ::
          {:ok, Hyper.GuestService.name(), binary()} | :more | {:error, :too_long | :bad_name}
  def parse(buffer) do
    case :binary.match(buffer, <<0>>) do
      {at, 1} when at < @max_bytes -> named(buffer, at)
      {_at, 1} -> {:error, :too_long}
      :nomatch when byte_size(buffer) >= @max_bytes -> {:error, :too_long}
      :nomatch -> partial(buffer)
    end
  end

  @spec valid_name?(term()) :: boolean()
  def valid_name?(name) when is_binary(name), do: Regex.match?(@name, name)
  def valid_name?(_), do: false

  defp named(buffer, at) do
    <<name::binary-size(^at), 0, rest::binary>> = buffer
    if valid_name?(name), do: {:ok, name, rest}, else: {:error, :bad_name}
  end

  defp partial(""), do: :more

  defp partial(buffer) do
    if valid_name?(buffer), do: :more, else: {:error, :bad_name}
  end
end
