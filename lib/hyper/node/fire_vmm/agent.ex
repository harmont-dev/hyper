defmodule Hyper.Node.FireVMM.Agent do
  @moduledoc """
  gRPC client to the in-guest agent, dialed through the per-VM relay UDS.

  `relay_socket_path/1` is the single source of truth for the host-side
  Unix-domain socket the relay listens on. The relay GenServer (Task 7) will
  call this function to derive its own listen path, so both sides agree
  without a process-registry lookup.
  """

  alias Hyper.Agent.V1.{ExecRequest, GuestAgent.Stub}

  # GRPC.Status codes stored as module attributes so they can be used in
  # guard-equivalent pattern matches without calling functions at match time.
  @unavailable GRPC.Status.unavailable()
  @deadline_exceeded GRPC.Status.deadline_exceeded()

  @default_timeout 30_000

  @doc """
  Deterministic host-side path for the per-VM relay Unix socket.

  Derived from `Hyper.Cfg.Dirs.socket_dir/0` so both this client and the
  relay GenServer agree without a registry lookup.

  Task 7: the relay GenServer listens here.
  """
  @spec relay_socket_path(Hyper.Vm.Id.t()) :: Path.t()
  def relay_socket_path(vm_id) do
    # Vm.Id chars are [a-z2-7] plus a 'v' prefix — safe as a filename
    # component without further sanitization.
    Path.join(Hyper.Cfg.Dirs.socket_dir(), "grpc-#{vm_id}.sock")
  end

  @doc """
  Run `argv` in the guest VM identified by `vm_id` via gRPC through the relay.

  Returns `{:ok, %{stdout: binary(), stderr: binary(), exit_code: integer()}}`,
  or `{:error, term()}`. Error values: `:agent_unavailable` (relay unreachable —
  gRPC UNAVAILABLE), `:timeout` (gRPC DEADLINE_EXCEEDED), or raw transport
  errors for unexpected failures.

  ## Options

    - `:env` — environment map `%{String.t() => String.t()}` for the guest process
    - `:cwd` — working directory inside the guest (`nil` → not set)
    - `:timeout` — gRPC deadline in milliseconds (default: #{@default_timeout})
  """
  @spec exec(Hyper.Vm.Id.t(), [String.t()], keyword()) ::
          {:ok, %{stdout: binary(), stderr: binary(), exit_code: integer()}}
          | {:error, term()}
  def exec(vm_id, argv, opts \\ []) do
    path = relay_socket_path(vm_id)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    req = %ExecRequest{
      argv: argv,
      env: Map.new(Keyword.get(opts, :env, %{})),
      cwd: opts[:cwd]
    }

    case GRPC.Stub.connect("unix://" <> path, adapter: GRPC.Client.Adapters.Gun) do
      {:error, _} = err ->
        map_grpc_error(err)

      {:ok, ch} ->
        try do
          ch |> call(req, timeout) |> await(timeout)
        after
          _ = GRPC.Stub.disconnect(ch)
        end
    end
  end

  @spec call(GRPC.Channel.t(), ExecRequest.t(), timeout()) :: Task.t()
  defp call(ch, req, timeout) do
    Task.async(fn ->
      try do
        Stub.exec(ch, req, timeout: timeout)
      rescue
        e -> {:error, {:bad_agent_reply, e.__struct__}}
      catch
        :exit, reason -> {:error, {:bad_agent_reply, reason}}
      end
    end)
  end

  @spec await(Task.t(), timeout()) ::
          {:ok, %{stdout: binary(), stderr: binary(), exit_code: integer()}} | {:error, term()}
  defp await(task, timeout) do
    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, resp}} ->
        {:ok, %{exit_code: resp.exit_code, stdout: resp.stdout, stderr: resp.stderr}}

      {:ok, err} ->
        map_grpc_error(err)

      _ ->
        {:error, :timeout}
    end
  end

  @spec map_grpc_error({:error, term()}) :: {:error, term()}
  defp map_grpc_error({:error, %GRPC.RPCError{status: @unavailable}}),
    do: {:error, :agent_unavailable}

  defp map_grpc_error({:error, %GRPC.RPCError{status: @deadline_exceeded}}),
    do: {:error, :timeout}

  defp map_grpc_error({:error, _} = err), do: err
end
