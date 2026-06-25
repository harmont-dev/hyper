defmodule Hyper.Firecracker.Api.Transport do
  @moduledoc """
  `oapi_generator` client backend for the Firecracker API. Each generated
  operation calls `request/1` with a plain map describing the call; this issues
  it over the target daemon's HTTP-over-Unix-socket API via `Req` and decodes the
  typed response.

  The per-VM socket path arrives as `opts[:socket_path]` (injected by
  `Hyper.Node.FireVMM.Client`). Request bodies are generated structs encoded by
  `Hyper.Firecracker.Api.Codec` (nil-stripped) or, for free-form bodies like
  MMDS, plain maps sent verbatim. Typed responses are decoded by the schema's
  own generated `decode/1` (also from `Hyper.Firecracker.Api.Codec`).

  Returns: `:ok` (204 / empty), `{:ok, decoded}` (2xx with a typed body),
  `{:error, {:api, status, fault_message}}` (non-2xx), or
  `{:error, {:transport, reason}}` (socket/connection failure).
  """

  use OpenTelemetryDecorator

  @type result ::
          :ok
          | {:ok, term()}
          | {:error, {:api, pos_integer(), String.t() | nil} | {:transport, term()}}

  @spec request(map()) :: result()
  @decorate with_span("Hyper.Firecracker.Api.Transport.request", include: [:method, :url])
  def request(%{method: method, url: url, opts: opts} = info) do
    socket_path = Keyword.fetch!(opts, :socket_path)

    req =
      Req.new(
        base_url: "http://localhost",
        unix_socket: socket_path,
        retry: false,
        receive_timeout: 30_000
      )

    req_opts = [method: method, url: url]

    req_opts =
      if Map.has_key?(info, :body), do: Keyword.put(req_opts, :json, info.body), else: req_opts

    req_opts = if q = info[:query], do: Keyword.put(req_opts, :params, q), else: req_opts

    case Req.request(req, req_opts) do
      {:ok, %Req.Response{status: status, body: body}} ->
        handle(status, body, Map.get(info, :response, []))

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  @spec handle(pos_integer(), term(), [{pos_integer(), term()}]) :: result()
  defp handle(status, body, responses) when status in 200..299 do
    case List.keyfind(responses, status, 0) do
      {^status, :null} -> :ok
      {^status, {module, :t}} -> {:ok, module.decode(body)}
      _other -> if body in [nil, ""], do: :ok, else: {:ok, body}
    end
  end

  defp handle(status, body, _responses), do: {:error, {:api, status, fault(body)}}

  @spec fault(term()) :: String.t() | nil
  defp fault(%{"fault_message" => message}), do: message
  defp fault(_), do: nil
end
