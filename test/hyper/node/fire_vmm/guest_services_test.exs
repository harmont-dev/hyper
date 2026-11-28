defmodule Hyper.Node.FireVMM.GuestServicesTest do
  @moduledoc false
  # async: false -- the helper stub and the work_dir cache are process-global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Hyper.GuestService
  alias Hyper.GuestService.{Conn, Relay}
  alias Hyper.Node.FireVMM.GuestServices.Listener
  alias Hyper.Node.FireVMM.Jailer
  alias Unit.Information

  @vm_id "vguestsvc"

  defmodule Echo do
    @moduledoc false
    @behaviour Hyper.GuestService.Handler
    def name, do: "echo"
    def init(conn, test), do: {:ok, %{conn: conn, test: test}}
    def handle_data("whoami", state), do: {:reply, state.conn.vm_id, state}

    def handle_data("later", state) do
      send(self(), :tick)
      {:continue, state}
    end

    def handle_data("bye", state), do: {:close, state}
    def handle_data(data, state), do: {:reply, data, state}
    def handle_info(:tick, state), do: {:reply, "tick", state}
    def terminate(reason, state), do: send(state.test, {:terminated, reason})
  end

  defmodule Crash do
    @moduledoc false
    @behaviour Hyper.GuestService.Handler
    def name, do: "crash"
    def init(_conn, test), do: {:ok, test}
    def handle_data(data, _test), do: raise(ArgumentError, "unparseable request: " <> data)
  end

  defmodule Hoard do
    @moduledoc false
    @behaviour Hyper.GuestService.Handler
    def name, do: "hoard"
    def init(_conn, _arg), do: {:ok, ""}
    def handle_data(data, held), do: {:continue, held <> data}
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "guest-services-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    original = Hyper.Cfg.Toml.reload()
    :ok = Hyper.Cfg.Toml.put_cache(Map.put(original, "work_dir", tmp))
    on_exit(fn -> Hyper.Cfg.Toml.reload() end)
    File.mkdir_p!(Hyper.Cfg.Dirs.socket_dir())
    :ok
  end

  defp start(services) do
    {:ok, services} = GuestService.resolve_all(services)
    start_supervised!({Listener, %Listener.Opts{vm_id: @vm_id, services: services}})
  end

  defp echo(overrides \\ []),
    do: struct!(%GuestService{handler: {Echo, self()}}, overrides)

  defp guest(header) do
    {:ok, sock} =
      :gen_tcp.connect({:local, Jailer.host_guest_socket(@vm_id)}, 0, [:binary, active: false])

    :ok = :gen_tcp.send(sock, header)
    sock
  end

  defp ask(sock, data) do
    :ok = :gen_tcp.send(sock, data)
    :gen_tcp.recv(sock, 0, 2_000)
  end

  test "a guest naming an attached service talks to its handler, from the bytes behind the name" do
    start([echo()])
    sock = guest("echo\0hello")

    assert :gen_tcp.recv(sock, 0, 2_000) == {:ok, "hello"}
    assert ask(sock, "again") == {:ok, "again"}
  end

  test "the handler learns which VM is asking from the connection, not from the guest" do
    start([echo()])
    assert ask(guest("echo\0"), "whoami") == {:ok, @vm_id}
  end

  test "pushes from the handler reach the guest" do
    start([echo()])
    assert ask(guest("echo\0"), "later") == {:ok, "tick"}
  end

  test "a refused header is closed without a byte sent back" do
    start([echo()])

    for header <- ["nope\0", "Echo\0", "\0", String.duplicate("a", 256), "ec ho\0"] do
      assert :gen_tcp.recv(guest(header), 0, 2_000) == {:error, :closed}, inspect(header)
    end
  end

  test "a guest that never finishes its header is closed" do
    start([echo()])
    assert :gen_tcp.recv(guest("ech"), 0, 7_000) == {:error, :closed}
  end

  test "a handler that raises loses its own connection only, and logs a bounded line" do
    start([echo(), %GuestService{handler: {Crash, self()}}])
    secret = String.duplicate("z", 10_000)

    log =
      capture_log(fn ->
        assert ask(guest("crash\0"), secret) == {:error, :closed}
      end)

    assert log =~ "guest service crash: handler failed"
    assert byte_size(log) < 2_000
    assert ask(guest("echo\0"), "still here") == {:ok, "still here"}
  end

  test "a handler holding more guest bytes than the heap cap is killed, and only its own " <>
         "connection drops" do
    start([echo(), %GuestService{handler: {Hoard, nil}}])
    sock = guest("hoard\0")
    chunk = :binary.copy("x", Information.as_bytes(Information.mib(1)))

    capture_log(fn ->
      Enum.reduce_while(1..96, :ok, fn _mib, :ok ->
        case :gen_tcp.send(sock, chunk) do
          :ok -> {:cont, :ok}
          {:error, _closed} -> {:halt, :ok}
        end
      end)

      assert :gen_tcp.recv(sock, 0, 5_000) == {:error, :closed}
    end)

    assert ask(guest("echo\0"), "still here") == {:ok, "still here"}
  end

  test "a service at its cap refuses the next guest, and admits again once a slot frees" do
    start([echo(max_connections: 1)])
    first = guest("echo\0")
    assert ask(first, "one") == {:ok, "one"}

    assert :gen_tcp.recv(guest("echo\0"), 0, 2_000) == {:error, :closed}

    :ok = :gen_tcp.close(first)
    assert Hyper.E2e.poll_until(fn -> ask(guest("echo\0"), "two") == {:ok, "two"} end, 2_000)
  end

  test "the handler closing hangs up the guest and runs terminate" do
    start([echo()])
    assert ask(guest("echo\0"), "bye") == {:error, :closed}
    assert_receive {:terminated, :normal}
  end

  test "stopping the services hangs up every guest and runs each handler's terminate" do
    start([echo()])
    socks = for _ <- 1..3, do: guest("echo\0")
    for sock <- socks, do: assert(ask(sock, "up") == {:ok, "up"})

    :ok = stop_supervised(Listener)

    for sock <- socks, do: assert(:gen_tcp.recv(sock, 0, 2_000) == {:error, :closed})
    for _ <- socks, do: assert_receive({:terminated, :shutdown})
    refute File.exists?(Jailer.host_guest_socket(@vm_id))
  end

  test "a relay carries the guest's bytes to its target, and the target's replies back" do
    start([%GuestService{handler: {Relay, self()}}])
    sock = guest("relay\0hello")

    assert_receive {:guest_service_open, relay, %Conn{vm_id: @vm_id, service: "relay"}}
    assert_receive {:guest_service_data, ^relay, "hello"}
    send(relay, {:guest_service_reply, "hi"})
    assert :gen_tcp.recv(sock, 0, 2_000) == {:ok, "hi"}

    :ok = :gen_tcp.send(sock, "again")
    assert_receive {:guest_service_data, ^relay, "again"}
  end

  test "a relay's target closing hangs up the guest" do
    start([%GuestService{handler: {Relay, self()}}])
    sock = guest("relay\0")

    assert_receive {:guest_service_open, relay, _conn}
    send(relay, :guest_service_close)
    assert :gen_tcp.recv(sock, 0, 2_000) == {:error, :closed}
  end

  test "a relay whose target is down hangs up the guest instead of leaving it waiting" do
    gone = spawn(fn -> :ok end)

    start([
      %GuestService{name: "gone", handler: {Relay, gone}},
      %GuestService{name: "unregistered", handler: {Relay, {:nobody, node()}}}
    ])

    for name <- ["gone", "unregistered"] do
      assert :gen_tcp.recv(guest(name <> "\0"), 0, 2_000) == {:error, :closed}, name
    end
  end
end
