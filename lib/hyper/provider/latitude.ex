defmodule Hyper.Provider.Latitude do
  @moduledoc """
  `Hyper.Provider` implementation backed by the [Latitude.sh](https://www.latitude.sh)
  bare-metal API.

  The API is JSON:API shaped: every request and response wraps its payload in a
  `{"data": {"type": ..., "attributes": ...}}` envelope, authenticated with a
  `Authorization: Bearer <token>` header.

  Provisioning is a three-step dance, because Latitude does not accept an inline
  cloud-init script on server create — the script is a separate, project-scoped
  resource referenced by id:

    1. base64-encode the script and `POST /projects/{project}/user_data`,
       reading back its `ud_…` id;
    2. `POST /servers` with that id under `attributes.user_data`;
    3. poll `GET /servers/{id}` until `attributes.status` is `"on"` (treating
       `"failed_deployment"` as a terminal failure), then read the public IPv4
       from `attributes.primary_ipv4`.

  The `t:Hyper.Provider.cfg/0` map may use atom or string keys and carries:
  `:token`, `:project`, `:plan`, `:operating_system`, `:site`,
  `:hostname_prefix`, `:ssh_keys` (list), `:billing`.

  Any non-2xx response is surfaced as `{:error, {:latitude, status, body}}`.
  """

  @behaviour Hyper.Provider

  require Logger

  @base_url "https://api.latitude.sh"

  @ready_status "on"
  @failed_status "failed_deployment"

  @poll_interval_ms 10_000
  @poll_max_attempts 60

  @default_hostname_prefix "hyper"

  @impl Hyper.Provider
  @spec cfg_namespace() :: String.t()
  def cfg_namespace, do: "latitude"

  @impl Hyper.Provider
  @spec template_segments() :: [String.t()]
  def template_segments, do: ["priv", "deploy", "latitude", "user-data.sh.eex"]

  @impl Hyper.Provider
  @spec validate_cfg(Hyper.Provider.cfg()) :: :ok | {:error, term()}
  def validate_cfg(cfg) do
    case Enum.reject([:token, :project, :plan, :site, :operating_system], &optional_cfg(cfg, &1)) do
      [] -> :ok
      missing -> {:error, {:latitude, :missing_cfg, missing}}
    end
  end

  @impl Hyper.Provider
  @spec create_node(Hyper.Provider.cfg(), String.t()) ::
          {:ok, Hyper.Provider.node_ref()} | {:error, term()}
  def create_node(cfg, user_data) do
    with {:ok, token} <- require_cfg(cfg, :token),
         {:ok, project} <- require_cfg(cfg, :project),
         {:ok, user_data_id} <- create_user_data(token, project, user_data),
         {:ok, server_id} <- create_server(cfg, token, user_data_id) do
      poll_ready(token, server_id, @poll_max_attempts)
    end
  end

  @impl Hyper.Provider
  @spec destroy_node(Hyper.Provider.cfg(), String.t()) :: :ok | {:error, term()}
  def destroy_node(cfg, ref) do
    with {:ok, token} <- require_cfg(cfg, :token) do
      case request(token, :delete, "/servers/#{ref}", []) do
        {:ok, _body} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl Hyper.Provider
  @spec list_nodes(Hyper.Provider.cfg()) ::
          {:ok, [Hyper.Provider.node_ref()]} | {:error, term()}
  def list_nodes(cfg) do
    with {:ok, token} <- require_cfg(cfg, :token),
         {:ok, project} <- require_cfg(cfg, :project) do
      case request(token, :get, "/servers", params: %{"filter[project]" => project}) do
        {:ok, %{"data" => items}} when is_list(items) ->
          {:ok, Enum.map(items, &to_node_ref/1)}

        {:ok, other} ->
          Logger.warning("latitude list_nodes: unexpected body shape: #{inspect(other)}")
          {:error, {:latitude, :unexpected_list_response, other}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec create_user_data(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  defp create_user_data(token, project, user_data) do
    body = %{
      data: %{
        type: "user_data",
        attributes: %{
          description: "hyper bootstrap",
          content: Base.encode64(user_data)
        }
      }
    }

    case request(token, :post, "/projects/#{project}/user_data", json: body) do
      {:ok, %{"data" => %{"id" => id}}} when is_binary(id) ->
        {:ok, id}

      {:ok, other} ->
        Logger.warning("latitude create_user_data: no id in body: #{inspect(other)}")
        {:error, {:latitude, :unexpected_user_data_response, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec create_server(Hyper.Provider.cfg(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  defp create_server(cfg, token, user_data_id) do
    with {:ok, project} <- require_cfg(cfg, :project),
         {:ok, plan} <- require_cfg(cfg, :plan),
         {:ok, site} <- require_cfg(cfg, :site),
         {:ok, operating_system} <- require_cfg(cfg, :operating_system) do
      attributes =
        %{
          project: project,
          plan: plan,
          site: site,
          operating_system: operating_system,
          hostname: build_hostname(cfg),
          user_data: user_data_id
        }
        |> maybe_put(:ssh_keys, optional_cfg(cfg, :ssh_keys))
        |> maybe_put(:billing, optional_cfg(cfg, :billing))

      body = %{data: %{type: "servers", attributes: attributes}}

      case request(token, :post, "/servers", json: body) do
        {:ok, %{"data" => %{"id" => id}}} when is_binary(id) ->
          {:ok, id}

        {:ok, other} ->
          Logger.warning("latitude create_server: no id in body: #{inspect(other)}")
          {:error, {:latitude, :unexpected_server_response, other}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec poll_ready(String.t(), String.t(), non_neg_integer()) ::
          {:ok, Hyper.Provider.node_ref()} | {:error, term()}
  defp poll_ready(_token, server_id, 0), do: {:error, {:latitude, :poll_timeout, server_id}}

  defp poll_ready(token, server_id, attempts_left) do
    case request(token, :get, "/servers/#{server_id}", []) do
      {:ok, %{"data" => %{"attributes" => attrs}}} when is_map(attrs) ->
        status = Map.get(attrs, "status")

        cond do
          status == @ready_status ->
            {:ok,
             %{
               ref: server_id,
               hostname: Map.get(attrs, "hostname") || "",
               ip: Map.get(attrs, "primary_ipv4"),
               status: status
             }}

          status == @failed_status ->
            Logger.warning("latitude poll: server #{server_id} failed deployment")
            {:error, {:latitude, :failed_deployment, server_id}}

          true ->
            Process.sleep(@poll_interval_ms)
            poll_ready(token, server_id, attempts_left - 1)
        end

      {:ok, other} ->
        Logger.warning("latitude poll: unexpected body shape: #{inspect(other)}")
        {:error, {:latitude, :unexpected_get_response, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec to_node_ref(term()) :: Hyper.Provider.node_ref()
  defp to_node_ref(item) when is_map(item) do
    attrs = Map.get(item, "attributes", %{})

    %{
      ref: Map.get(item, "id") || "",
      hostname: Map.get(attrs, "hostname") || "",
      ip: Map.get(attrs, "primary_ipv4"),
      status: Map.get(attrs, "status") || "unknown"
    }
  end

  @spec build_hostname(Hyper.Provider.cfg()) :: String.t()
  defp build_hostname(cfg) do
    prefix = optional_cfg(cfg, :hostname_prefix) || @default_hostname_prefix
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end

  @spec request(String.t(), atom(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  defp request(token, method, path, opts) do
    req =
      Req.new(
        base_url: @base_url,
        auth: {:bearer, token},
        retry: false,
        receive_timeout: 30_000
      )

    req_opts = [method: method, url: path] ++ opts

    case Req.request(req, req_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("latitude #{method} #{path}: HTTP #{status}")
        {:error, {:latitude, status, body}}

      {:error, reason} ->
        Logger.warning("latitude #{method} #{path}: transport error #{inspect(reason)}")
        {:error, {:latitude, :transport, reason}}
    end
  end

  @spec require_cfg(Hyper.Provider.cfg(), atom()) :: {:ok, term()} | {:error, term()}
  defp require_cfg(cfg, key) do
    case optional_cfg(cfg, key) do
      nil -> {:error, {:latitude, :missing_cfg, key}}
      value -> {:ok, value}
    end
  end

  @spec optional_cfg(Hyper.Provider.cfg(), atom()) :: term() | nil
  defp optional_cfg(cfg, key) do
    Map.get(cfg, key, Map.get(cfg, Atom.to_string(key)))
  end

  @spec maybe_put(map(), atom(), term()) :: map()
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
