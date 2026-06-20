defmodule Hyper.Node.FireVMM.Client do
  @moduledoc """
  GenServer owning the HTTP-over-Unix-socket API connection to a single
  Firecracker daemon (one per microVM). Firecracker's API server is
  single-threaded, so every request is serialized through this process'
  `handle_call/3`.

  Transport is `Req` with its `:unix_socket` option pointed at the daemon's
  API socket. Request bodies are `Schema.*` structs, nil-stripped by
  `Body.encode/1`; responses are decoded to maps (200) or `:ok` (204). Errors
  surface as `{:error, {:api, status, fault_message}}` (Firecracker `Error`
  body) or `{:error, {:transport, reason}}` (socket not up, connection refused).

  Registered cluster-wide via `Hyper.Cluster.Routing.via({vm_id, :client})`.
  """

  use GenServer

  alias Hyper.Node.FireVMM.Client.{Body, Schema}

  defmodule Opts do
    @moduledoc "Start options for `Hyper.Node.FireVMM.Client`."
    @enforce_keys [:vm_id, :socket_path]
    defstruct [:vm_id, :socket_path, :name, req_options: []]

    @type t :: %__MODULE__{
            vm_id: integer() | nil,
            socket_path: Path.t(),
            name: GenServer.name() | nil,
            req_options: keyword()
          }
  end

  defmodule State do
    @moduledoc false
    @enforce_keys [:req]
    defstruct [:req]
    @type t :: %__MODULE__{req: Req.Request.t()}
  end

  @type server :: GenServer.server()
  @type result ::
          :ok
          | {:ok, map()}
          | {:error, {:api, pos_integer(), String.t() | nil} | {:transport, term()}}

  @spec start_link(Opts.t()) :: GenServer.on_start()
  def start_link(%Opts{} = opts) do
    name =
      case opts.name do
        nil when not is_nil(opts.vm_id) -> via(opts.vm_id)
        other -> other
      end

    GenServer.start_link(__MODULE__, opts, gen_opts(name))
  end

  @spec via(integer()) :: GenServer.name()
  def via(vm_id), do: Hyper.Cluster.Routing.via({vm_id, :client})

  @doc "GET / — instance information (state, id, version)."
  @spec instance_info(server()) :: result()
  def instance_info(server), do: call(server, :get, "/")

  @doc "PUT /actions — perform an instance action (e.g. InstanceStart)."
  @spec action(server(), Schema.InstanceActionInfo.t()) :: result()
  def action(server, %Schema.InstanceActionInfo{} = a), do: call(server, :put, "/actions", a)

  @doc "PUT /boot-source — configure the boot source (pre-boot)."
  @spec put_boot_source(server(), Schema.BootSource.t()) :: result()
  def put_boot_source(server, %Schema.BootSource{} = b), do: call(server, :put, "/boot-source", b)

  ## Transport

  @spec call(server(), :get | :put | :patch, String.t()) :: result()
  @spec call(server(), :get | :put | :patch, String.t(), struct() | map() | nil) :: result()
  defp call(server, method, path, body \\ nil) do
    GenServer.call(server, {:request, method, path, body})
  end

  @impl true
  @spec init(Opts.t()) :: {:ok, State.t()}
  def init(%Opts{socket_path: socket_path, req_options: req_options}) do
    req =
      Req.new(
        [base_url: "http://localhost", unix_socket: socket_path, retry: false]
        |> Keyword.merge(req_options)
      )

    {:ok, %State{req: req}}
  end

  @impl true
  def handle_call({:request, method, path, body}, _from, %State{req: req} = state) do
    opts = [method: method, url: path]
    opts = if is_nil(body), do: opts, else: Keyword.put(opts, :json, Body.encode(body))

    {:reply, run(req, opts), state}
  end

  @spec run(Req.Request.t(), keyword()) :: result()
  defp run(req, opts) do
    case Req.request(req, opts) do
      {:ok, %Req.Response{status: status, body: rbody}} when status in 200..299 ->
        success(status, rbody)

      {:ok, %Req.Response{status: status, body: rbody}} ->
        {:error, {:api, status, fault(rbody)}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  @spec success(pos_integer(), term()) :: :ok | {:ok, map()}
  defp success(204, _body), do: :ok
  defp success(_status, body) when body in ["", nil], do: :ok
  defp success(_status, body) when is_map(body), do: {:ok, body}
  defp success(_status, _body), do: :ok

  @spec fault(term()) :: String.t() | nil
  defp fault(%{"fault_message" => msg}), do: msg
  defp fault(_), do: nil

  @spec gen_opts(GenServer.name() | nil) :: [{:name, GenServer.name()}]
  defp gen_opts(nil), do: []
  defp gen_opts(name), do: [name: name]
end
