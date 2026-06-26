defmodule Hyper.Cfg.GrpcTest do
  use ExUnit.Case, async: false

  alias Hyper.Cfg.Grpc
  alias Hyper.Cfg.Toml

  setup do
    Application.delete_env(:hyper, Grpc)
    Toml.put_cache(%{})

    on_exit(fn ->
      Application.delete_env(:hyper, Grpc)
      Toml.reload()
    end)

    :ok
  end

  test "defaults: disabled on 50051, no cred" do
    cfg = Grpc.load()
    assert cfg.enabled == false
    assert cfg.port == 50_051
    assert cfg.cred == nil
  end

  test "reads enabled/port from [grpc] toml" do
    Toml.put_cache(%{"grpc" => %{"enabled" => true, "port" => 6000}})
    cfg = Grpc.load()
    assert cfg.enabled == true
    assert cfg.port == 6000
  end

  test "builds a credential from a toml inline table" do
    Toml.put_cache(%{"grpc" => %{"cred" => %{"cert" => "/c.pem", "key" => "/k.pem"}}})
    cfg = Grpc.load()
    assert match?(%GRPC.Credential{}, cfg.cred)
  end

  test "config.exs wins over toml" do
    Toml.put_cache(%{"grpc" => %{"port" => 6000}})
    Application.put_env(:hyper, Grpc, port: 7000)
    assert Grpc.load().port == 7000
  end
end
