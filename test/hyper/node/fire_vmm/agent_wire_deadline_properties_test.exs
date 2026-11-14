defmodule Hyper.Node.FireVMM.AgentWireDeadlinePropertiesTest do
  @moduledoc """
  The deadline `Agent.exec/3` puts on the wire must be the caller's own
  (#132: `:timeout` is the deadline for the whole call).

  The guest agent (tonic) enforces the request's `grpc-timeout` header and
  answers `CANCELLED "Timeout expired"` when it lapses. So the law is: for
  every `:timeout`, the `grpc-timeout` the guest receives, decoded per the
  gRPC HTTP/2 spec (`n u m S M H`), is never shorter than `:timeout` — or the
  guest abandons the call before the host's deadline and the caller gets a
  raw `CANCELLED` instead of `{:error, :timeout}`, early.

  The decoder below is an independent oracle written from the spec, not the
  client's own codec.

  `async: false`: `Hyper.Cfg.Toml.put_cache/1` is process-global.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Hyper.Agent.V1.ExecResponse
  alias Hyper.Node.FireVMM.Agent

  @vm_id "vwiredeadline"

  defmodule Reflect do
    @moduledoc false

    def init(req, state) do
      {:ok, _body, req} = :cowboy_req.read_body(req)
      header = :cowboy_req.header("grpc-timeout", req, "")
      msg = ExecResponse.encode(%ExecResponse{exit_code: 0, stdout: header})
      req = :cowboy_req.stream_reply(200, %{"content-type" => "application/grpc"}, req)
      :cowboy_req.stream_body(<<0, byte_size(msg)::32, msg::binary>>, :nofin, req)
      :cowboy_req.stream_trailers(%{"grpc-status" => "0"}, req)
      {:ok, req, state}
    end
  end

  setup_all do
    {:ok, _} = Application.ensure_all_started(:grpc)
    {:ok, _} = Application.ensure_all_started(:cowboy)
    original = Hyper.Cfg.Toml.reload()
    tmp = Path.join(System.tmp_dir!(), "agent-wire-#{System.unique_integer([:positive])}")
    :ok = Hyper.Cfg.Toml.put_cache(Map.put(original, "work_dir", tmp))
    File.mkdir_p!(Hyper.Cfg.Dirs.socket_dir())

    dispatch = :cowboy_router.compile([{:_, [{:_, Reflect, nil}]}])

    {:ok, _} =
      :cowboy.start_clear(
        {__MODULE__, @vm_id},
        [ip: {:local, Agent.relay_socket_path(@vm_id)}, port: 0],
        %{env: %{dispatch: dispatch}, protocols: [:http2]}
      )

    on_exit(fn ->
      :cowboy.stop_listener({__MODULE__, @vm_id})
      Hyper.Cfg.Toml.put_cache(original)
      File.rm_rf(tmp)
    end)

    :ok
  end

  @unit_ns %{
    "n" => 1,
    "u" => 1_000,
    "m" => 1_000_000,
    "S" => 1_000_000_000,
    "M" => 60_000_000_000,
    "H" => 3_600_000_000_000
  }

  defp wire_ns(header) do
    {digits, unit} = String.split_at(header, -1)
    assert digits =~ ~r/\A[0-9]{1,8}\z/, "malformed grpc-timeout #{inspect(header)}"
    String.to_integer(digits) * Map.fetch!(@unit_ns, unit)
  end

  defp wire_timeout_ms(timeout_ms) do
    {:ok, %{stdout: header}} = Agent.exec(@vm_id, ["/bin/true"], timeout: timeout_ms)
    {header, wire_ns(header) / 1_000_000}
  end

  property "the guest is never told a shorter deadline than the caller asked for" do
    check all(
            timeout_ms <-
              one_of([integer(1..999), integer(1_000..59_999), integer(60_000..7_200_000)]),
            max_runs: 100
          ) do
      {header, wire_ms} = wire_timeout_ms(timeout_ms)

      assert wire_ms >= timeout_ms,
             "timeout: #{timeout_ms}ms went on the wire as #{header} (#{wire_ms}ms)"
    end
  end

  test "concrete deadlines the guest would cut short" do
    rows = [1_500, 1_999, 30_000, 90_000, 119_000]

    shortened =
      for t <- rows, {header, wire_ms} = wire_timeout_ms(t), wire_ms < t, do: {t, header}

    assert shortened == []
  end
end
