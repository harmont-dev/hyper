defmodule Hyper.Http.Router do
  @moduledoc """
  Public HTTP interface for Hyper VMs.

    * `GET /health` - liveness probe; no dependency checks.
    * `GET /ready` - readiness probe for the database and cluster.
    * `GET /v1/vms` - list VMs using `page_size` and `page_token`; responds with
      `vms` and `next_page_token`.
    * `POST /v1/vms` - create a VM from `image`, `instance_type`, `boot_args`,
      and optional `arch` and `label`.
    * `GET /v1/vms/:id` - get one VM.
    * `POST /v1/vms/:id/fork` - fork a VM.
    * `DELETE /v1/vms/:id` - stop a VM.
    * `PUT /v1/vms/:id/firewall` - set a VM firewall.
    * `GET /v1/vms/:id/usage` - metered usage for a VM.
    * `POST /v1/vms/:id/exec` - execute a command in the guest.
    * `POST /v1/images` - load an OCI image.
  """

  use Plug.Router
  use Plug.ErrorHandler

  alias Hyper.Http.Plugs.VerifyRequest

  plug(:match)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(VerifyRequest,
    create_vm_fields: ["image", "instance_type", "boot_args"],
    paths: ["/v1/vms"]
  )

  plug(:dispatch)

  get "/health" do
    send_json_response(conn, 200, %{status: "Hyper System is live"})
  end

  get "/ready" do
    case Hyper.Http.Server.ready() do
      :ok ->
        send_json_response(conn, 200, %{status: "Hyper System DB and Cluster are ready"})

      :error ->
        send_json_response(conn, 503, %{
          status: "Hyper System DB and Cluster not ready, Please try again later"
        })
    end
  end

  # TODO - create a vm router and forward all requests that come from path /vm to it

  get "/v1/vms" do
    params = conn.query_params

    page_size =
      case Map.get(params, "page_size", "10") |> Integer.parse() do
        {size, ""} -> size
        _ -> 0
      end

    page_token = Map.get(params, "page_token", "")

    case Hyper.Http.Server.list_vms(page_size, page_token) do
      {:ok, vms, next_token} ->
        send_json_response(conn, 200, %{vms: vms, next_page_token: next_token})

      :error ->
        send_json_response(conn, 503, %{error: "Could not fetch VMs. Try again later"})
    end
  end

  post "/v1/vms" do
    case Hyper.Http.Server.create_vm(conn.body_params) do
      {:created, vm_id, node_id, ipv6} ->
        send_json_response(conn, 201, %{status: "created", vm_id: vm_id, node: node_id, ip_address: ipv6})

      {:error, :machine_unreachable} ->
        send_json_response(conn, 404, %{status: "Machine Unreachable"})

      {:error, _reason} ->
        send_json_response(conn, 503, %{error: "Could not create VM, Try again later"})
    end
  end

  get "/v1/vms/:id" do
    conn
    |> send_resp(201, "Get vms per id ")
  end

  post "/v1/vms/:id/fork" do
    conn
    |> send_resp(201, "Get vms per id ")
  end

  delete "/v1/vms/:id" do
    conn
    |> send_resp(201, "Get vms per id ")
  end

  put "/v1/vms/:id/firewall" do
    conn
    |> send_resp(201, "Get vms per id ")
  end

  get "/v1/vms/:id/usage" do
    conn
    |> send_resp(201, "Get vms per id ")
  end

  post "/v1/vms/:id/exec" do
    conn
    |> send_resp(201, "Get vms per id ")
  end

  # post "/v1/images" do
  #   conn
  #   |> send_resp(201, "Get vms per id ")
  # end

  match _ do
    send_json_response(conn, 404, "Oops! Endpoint not found")
  end

  defp send_json_response(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "store")
    |> send_resp(status, Jason.encode!(body))
  end

  @impl Plug.ErrorHandler
  def handle_errors(conn, %{kind: kind, reason: reason, stack: stack}) do
    IO.inspect(kind, label: :kind)
    IO.inspect(reason, label: :reason)
    IO.inspect(stack, label: :stack)

    %VerifyRequest.IncompleteRequestError{
      message: msg
    } = reason

    send_resp(conn, conn.status, msg)
  end
end
