defmodule Hyper.GrpcTest do
  use ExUnit.Case, async: true

  describe "server_children/0 with enabled: true" do
    setup do
      original = Application.get_env(:hyper, Hyper.Grpc)
      on_exit(fn -> Application.put_env(:hyper, Hyper.Grpc, original || []) end)
    end

    test "raises ArgumentError when tls_cert is nil" do
      Application.put_env(:hyper, Hyper.Grpc,
        enabled: true,
        port: 50_051,
        tls_cert: nil,
        tls_key: "/path/to/key.pem"
      )

      assert_raise ArgumentError, ~r/:tls_cert.*HYPER_GRPC_TLS_CERT/, fn ->
        Hyper.Grpc.server_children()
      end
    end

    test "raises ArgumentError when tls_key is nil" do
      Application.put_env(:hyper, Hyper.Grpc,
        enabled: true,
        port: 50_051,
        tls_cert: "/path/to/cert.pem",
        tls_key: nil
      )

      assert_raise ArgumentError, ~r/:tls_key.*HYPER_GRPC_TLS_KEY/, fn ->
        Hyper.Grpc.server_children()
      end
    end

    test "raises ArgumentError when tls_cert is missing from config" do
      Application.put_env(:hyper, Hyper.Grpc, enabled: true, port: 50_051, tls_key: "/k.pem")

      assert_raise ArgumentError, ~r/:tls_cert/, fn ->
        Hyper.Grpc.server_children()
      end
    end
  end
end
