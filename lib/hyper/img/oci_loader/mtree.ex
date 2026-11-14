defmodule Hyper.Img.OciLoader.Mtree do
  @moduledoc false

  import Bitwise

  @rootless_xattr "xattr.user.rootlesscontainers"
  @noop_id 0xFFFFFFFF

  @type owner :: {non_neg_integer(), non_neg_integer()}
  @type owners :: %{Path.t() => owner()}

  @spec read_owners(Path.t()) :: {:ok, owners()} | {:error, term()}
  def read_owners(bundle) do
    with {:ok, names} <- File.ls(bundle) do
      case Enum.filter(names, &String.ends_with?(&1, ".mtree")) do
        [name] ->
          with {:ok, text} <- File.read(Path.join(bundle, name)), do: owners(text)

        found ->
          {:error, {:mtree_not_found, found}}
      end
    end
  end

  @spec owners(String.t()) :: {:ok, owners()} | {:error, term()}
  def owners(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.reduce_while({[], %{}, %{}}, &step/2)
    |> case do
      {:error, _} = err -> err
      {_cwd, _defaults, owners} -> {:ok, owners}
    end
  end

  defp step(line, {cwd, defaults, owners}) do
    case String.split(line, [" ", "\t"], trim: true) do
      ["/set" | kvs] ->
        with {:ok, kws} <- keywords(kvs), do: {:cont, {cwd, Map.merge(defaults, kws), owners}}

      ["/unset" | keys] ->
        {:cont, {cwd, Map.drop(defaults, keys), owners}}

      [".."] when cwd != [] ->
        {:cont, {tl(cwd), defaults, owners}}

      [".."] ->
        halt_on_error(:error, line)

      [name | kvs] ->
        with {:ok, kws} <- keywords(kvs),
             {:ok, component} <- unvis(name),
             {:ok, owners} <- record(owners, cwd, component, kws) do
          kws = Map.merge(defaults, kws)
          cwd = if kws["type"] == "dir", do: [component | cwd], else: cwd
          {:cont, {cwd, defaults, owners}}
        end
        |> halt_on_error(line)
    end
  end

  defp halt_on_error({:cont, _} = cont, _line), do: cont
  defp halt_on_error(_error, line), do: {:halt, {:error, {:mtree_unparsable, line}}}

  defp keywords(kvs) do
    Enum.reduce_while(kvs, {:ok, %{}}, fn kv, {:ok, acc} ->
      case String.split(kv, "=", parts: 2) do
        [k, v] -> {:cont, {:ok, Map.put(acc, k, v)}}
        [_] -> {:halt, :error}
      end
    end)
  end

  defp record(owners, cwd, component, kws) do
    with false <- String.contains?(component, "/"),
         {:ok, owner} <- owner(kws) do
      path = [component | cwd] |> Enum.reverse() |> Enum.reject(&(&1 == ".")) |> Enum.join("/")
      {:ok, if(owner, do: Map.put(owners, path, owner), else: owners)}
    else
      _ -> :error
    end
  end

  defp owner(%{@rootless_xattr => encoded}) do
    with {:ok, bytes} <- Base.decode64(encoded, padding: false),
         {:ok, fields} <- protobuf_varints(bytes, %{}) do
      {:ok, {id(fields[1]), id(fields[2])}}
    end
  end

  defp owner(_kws), do: {:ok, nil}

  defp id(nil), do: 0
  defp id(@noop_id), do: 0
  defp id(n), do: n

  @doc false
  @spec protobuf_varints(binary(), map()) :: {:ok, %{pos_integer() => non_neg_integer()}} | :error
  def protobuf_varints(<<>>, acc), do: {:ok, acc}

  def protobuf_varints(bytes, acc) do
    with {:ok, tag, rest} <- varint(bytes),
         0 <- band(tag, 7),
         field when field in [1, 2] <- tag >>> 3,
         {:ok, value, rest} when value <= @noop_id <- varint(rest) do
      protobuf_varints(rest, Map.put(acc, field, value))
    else
      _ -> :error
    end
  end

  defp varint(bytes), do: varint(bytes, 0, 0)

  defp varint(<<1::1, low::7, rest::binary>>, shift, acc) when shift < 63,
    do: varint(rest, shift + 7, acc ||| low <<< shift)

  defp varint(<<0::1, low::7, rest::binary>>, shift, acc), do: {:ok, acc ||| low <<< shift, rest}
  defp varint(_bytes, _shift, _acc), do: :error

  @doc false
  @spec unvis(String.t()) :: {:ok, binary()} | :error
  def unvis(name), do: unvis(name, [])

  defp unvis(<<>>, acc), do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}
  defp unvis(<<?\\, ?\\, rest::binary>>, acc), do: unvis(rest, [?\\ | acc])

  defp unvis(<<?\\, a, b, c, rest::binary>>, acc)
       when a in ?0..?3 and b in ?0..?7 and c in ?0..?7,
       do: unvis(rest, [(a - ?0) * 64 + (b - ?0) * 8 + (c - ?0) | acc])

  defp unvis(<<?\\, _rest::binary>>, _acc), do: :error
  defp unvis(<<byte, rest::binary>>, acc), do: unvis(rest, [byte | acc])
end
