defmodule Hyper.Firecracker.Api.TransportOtelTest do
  use Hyper.OtelCase

  alias Hyper.Firecracker.Api.Transport

  setup do
    # Under `mix test --no-start` the app supervisor is not booted, so start the
    # HTTP client Transport uses. Idempotent if already running.
    {:ok, _} = Application.ensure_all_started(:req)
    :ok
  end

  test "request/1 emits a span even when the socket is unreachable" do
    # No daemon is listening on this socket, so the request fails fast with a
    # transport error — but the span must still be recorded around the attempt.
    result =
      Transport.request(%{
        method: :get,
        url: "/",
        opts: [socket_path: "/tmp/hyper-nonexistent-#{System.unique_integer([:positive])}.sock"]
      })

    assert {:error, {:transport, _reason}} = result
    assert_receive {:span, span(name: "Hyper.Firecracker.Api.Transport.request")}, 1_000
  end
end
