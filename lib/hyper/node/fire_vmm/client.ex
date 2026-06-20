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

  @doc "GET /machine-config."
  @spec get_machine_config(server()) :: result()
  def get_machine_config(server), do: call(server, :get, "/machine-config")

  @doc "PUT /machine-config (pre-boot)."
  @spec put_machine_config(server(), Schema.MachineConfiguration.t()) :: result()
  def put_machine_config(server, %Schema.MachineConfiguration{} = m),
    do: call(server, :put, "/machine-config", m)

  @doc "PATCH /machine-config (partial update, pre-boot)."
  @spec patch_machine_config(server(), Schema.MachineConfiguration.t()) :: result()
  def patch_machine_config(server, %Schema.MachineConfiguration{} = m),
    do: call(server, :patch, "/machine-config", m)

  @doc "PUT /drives/{drive_id}."
  @spec put_drive(server(), Schema.Drive.t()) :: result()
  def put_drive(server, %Schema.Drive{drive_id: id} = d),
    do: call(server, :put, "/drives/" <> id, d)

  @doc "PATCH /drives/{drive_id} (post-boot)."
  @spec patch_drive(server(), Schema.PartialDrive.t()) :: result()
  def patch_drive(server, %Schema.PartialDrive{drive_id: id} = d),
    do: call(server, :patch, "/drives/" <> id, d)

  @doc "PUT /network-interfaces/{iface_id}."
  @spec put_network_interface(server(), Schema.NetworkInterface.t()) :: result()
  def put_network_interface(server, %Schema.NetworkInterface{iface_id: id} = n),
    do: call(server, :put, "/network-interfaces/" <> id, n)

  @doc "PATCH /network-interfaces/{iface_id} (post-boot rate limiters)."
  @spec patch_network_interface(server(), Schema.PartialNetworkInterface.t()) :: result()
  def patch_network_interface(server, %Schema.PartialNetworkInterface{iface_id: id} = n),
    do: call(server, :patch, "/network-interfaces/" <> id, n)

  @doc "PATCH /vm — set running state (Paused | Resumed)."
  @spec patch_vm(server(), Schema.Vm.t()) :: result()
  def patch_vm(server, %Schema.Vm{} = v), do: call(server, :patch, "/vm", v)

  @doc "GET /vm/config — full VM configuration (raw map; keys are hyphenated)."
  @spec vm_config(server()) :: result()
  def vm_config(server), do: call(server, :get, "/vm/config")

  @doc "GET /version — Firecracker build version."
  @spec version(server()) :: result()
  def version(server), do: call(server, :get, "/version")

  @doc "GET /balloon."
  @spec get_balloon(server()) :: result()
  def get_balloon(server), do: call(server, :get, "/balloon")

  @doc "PUT /balloon (pre-boot)."
  @spec put_balloon(server(), Schema.Balloon.t()) :: result()
  def put_balloon(server, %Schema.Balloon{} = b), do: call(server, :put, "/balloon", b)

  @doc "PATCH /balloon — update target size (post-boot)."
  @spec patch_balloon(server(), Schema.BalloonUpdate.t()) :: result()
  def patch_balloon(server, %Schema.BalloonUpdate{} = b), do: call(server, :patch, "/balloon", b)

  @doc "GET /balloon/statistics."
  @spec get_balloon_stats(server()) :: result()
  def get_balloon_stats(server), do: call(server, :get, "/balloon/statistics")

  @doc "PATCH /balloon/statistics — update polling interval."
  @spec patch_balloon_stats(server(), Schema.BalloonStatsUpdate.t()) :: result()
  def patch_balloon_stats(server, %Schema.BalloonStatsUpdate{} = b),
    do: call(server, :patch, "/balloon/statistics", b)

  @doc "PATCH /balloon/hinting/start."
  @spec start_balloon_hinting(server(), Schema.BalloonStartCmd.t()) :: result()
  def start_balloon_hinting(server, %Schema.BalloonStartCmd{} = b),
    do: call(server, :patch, "/balloon/hinting/start", b)

  @doc "GET /balloon/hinting/status."
  @spec get_balloon_hinting_status(server()) :: result()
  def get_balloon_hinting_status(server), do: call(server, :get, "/balloon/hinting/status")

  @doc "PATCH /balloon/hinting/stop (no body)."
  @spec stop_balloon_hinting(server()) :: result()
  def stop_balloon_hinting(server), do: call(server, :patch, "/balloon/hinting/stop")

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
