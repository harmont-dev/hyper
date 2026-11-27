defmodule Hyper.Http.Router do
  @moduledoc """
  Public HTTP interface for Hyper VMs.

    * `GET /health` - liveness probe; no dependency checks.
    * `GET /ready` - readiness probe for the database and cluster.
    * `GET /v0/vms` - list VMs using `page_size` and `page_token`; responds with
      `vms` and `next_page_token`.
    * `POST /v0/vms` - create a VM from `image`, `instance_type`, `boot_args`,
      and optional `arch` and `label`.
    * `GET /v0/vms/:id` - get one VM.
    * `POST /v0/vms/:id/fork` - fork a VM.
    * `POST /v0/vms/:id` - stop a VM.
    * `PUT /v0/vms/:id/firewall` - set a VM firewall.
    * `GET /v0/vms/:id/usage` - metered usage for a VM.
    * `POST /v0/vms/:id/exec` - execute a command in the guest.
    * `POST /v0/images` - load an OCI image.
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
    paths: ["/v0/vms"]
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

  get "/v0/vms" do
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

      {:error, bad_page_token}->
        send_json_response(conn, 400, %{error: "Could not fetch VMs. Bad page token #{bad_page_token}"})
    end
  end

  post "/v0/vms" do
    case Hyper.Http.Server.create_vm(conn) do
      {:created, vm_id, node_id, ipv6} ->
        send_json_response(conn, 201, %{
          status: "created",
          vm_id: vm_id,
          node: node_id,
          ip_address: ipv6
        })

      {:error, :machine_unreachable} ->
        send_json_response(conn, 503, %{status: "Machine Unreachable"})

      {:error, _reason} ->
        send_json_response(conn, 503, %{error: "Could not create VM, Try again later"})
    end
  end

  get "/v0/vms/:id" do
    case Hyper.whereis(id) do
      nil -> send_json_response(conn, 404, %{status: "Not Found"})
      vm -> send_json_response(conn, 200, %{status: "Found", vm: vm})
    end
  end

  post "/v0/vms/:vm_id/fork" do
    case Hyper.fork_vm(vm_id) do
      {:ok, vm_id} ->
        id = Hyper.id(vm_id)

        if id == nil do
          send_json_response(conn, 503, %{status: "Machine Unreachable"})
        else
          send_json_response(conn, 201, %{status: "Forked", vm: node(vm_id)})
        end

      {:error, _} ->
        send_json_response(conn, 503, %{status: "Could not fork vm, try again later"})
    end
  end

  post "/v0/vms/:vm_id/stop" do
    case Hyper.stop_vm(vm_id) do
      :ok ->
        send_json_response(conn, 200, %{status: "Machine Stopped"})

      {:error, :not_found} ->
        send_json_response(conn, 404, %{status: "Machine with #{vm_id} not found"})

      {:error, :unreachable} ->
        send_json_response(conn, 404, %{status: "Machine Unreachable"})
    end
  end

  put "/v0/vms/:vm_id/set_firewall" do

    get_firewall = Map.get(conn.body_params, "firewall")

    case Hyper.Http.Server.set_firewall(vm_id, get_firewall) do
     :ok ->
        send_json_response(conn, 200, %{status: "Firewall set"})

     :not_found ->
        send_json_response(conn, 404, %{status: "Machine with #{vm_id} not found"})

     :unreachable ->
        send_json_response(conn, 404, %{status: "Machine Unreachable"})
    end

  end

  get "/v0/vms/:id/usage" do

    case Hyper.usage(id) do
      {:ok, vm_usage} ->
        send_json_response(conn, 200, %{vm_usage: vm_usage})

      {:error, :not_found} ->
        send_json_response(conn, 404, %{status: "Machine with #{id} not found"})
    end

  end

  post "/v0/vms/:id/exec" do
    conn
    |> send_resp(201, "Get vms per id ")
  end

  # post "/v0/images" do
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
