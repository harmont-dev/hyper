defmodule Hyper.Http.Server do
  require Logger
  def ready do
    result =
      case Application.get_env(:hyper, __MODULE__, [])[:ready] do
        fun when is_function(fun, 0) -> fun.()
        _ -> Hyper.Http.Server.Health.ready()
      end

    case result do
      {:ok, _} -> :ok
      {:error, _} -> :error
    end
  end

  def list_vms(page_size, page_token \\ "") do
    case Hyper.Grpc.Page.paginate(
           Hyper.Cluster.Routing.all(),
           page_size,
           page_token,
           Hyper.Grpc.Pageable.Vm
         ) do
      {:ok, {page, next}} ->
        {:ok,
         Enum.map(
           page,
           fn {vm_id, node} -> %{vm_id: vm_id, node: to_string(node)} end
         ), next}

      {:error, bad_page_token} ->  {:error, bad_page_token}
    end
  end

  # use the create_vm , build the spec, servers/grpc line 43, mirror the create vm , return the fields if it doesn't work just return an unreachable machine or the error
  # load image returns img_id
  def create_vm(%Plug.Conn{body_params: payload} = _conn) do
    %{
      "image" => image_ref,
      "boot_args" => boot_args,
      "type" => type
    } = payload

    arch = Map.get(payload, "architecture", nil)
    label = Map.get(payload, "label")

    case Hyper.Img.OciLoader.load(image_ref, label) do
      {:ok, img_id} ->
        spec = %Hyper.Vm.Spec{
          img_id: img_id,
          type: type,
          arch: arch,
          boot_args: boot_args
        }

        with {:ok, pid} <- Hyper.create_vm(spec),
             vm_id when is_binary(vm_id) <- Hyper.id(pid),
             {:ok, ipv6} <- Hyper.address(pid) do
          {:created, vm_id, node(pid), ipv6}
        else
          nil -> {:error, :machine_unreachable}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def set_firewall(vm_id, get_firewall) do

    firewall = %Hyper.Vm.Firewall{
      inbound: Map.get(get_firewall, "inbound"),
      outbound_blocked: Map.get(get_firewall, "outbound"),
    }

    Hyper.set_vm_firewall(vm_id, firewall)
  rescue
    e ->
      Logger.error("Failed to set firewall: #{Exception.message(e)}")
      {:error, :runtime_error}

  end
end
