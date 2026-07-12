defmodule Hyper.Cfg.GrpcTest do
  @moduledoc """
  Contracts on top of plain resolution: a `[grpc]` toml `cred` inline table
  (`{ cert = ..., key = ... }`) coerces into a `GRPC.Credential` while a
  pre-built credential passes through untouched; `server_options/1` omits
  `:cred` and `:adapter_opts` entirely at their plaintext defaults (a
  literal `cred: nil` reaching GRPC.Server.Supervisor is a different
  configuration than the key being absent) and carries them through when
  set.
  """
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

  test "a [grpc] toml table loads, with the cred inline table coerced to a GRPC.Credential" do
    Toml.put_cache(%{
      "grpc" => %{
        "enabled" => true,
        "port" => 50_061,
        "cred" => %{"cert" => "/etc/hyper/cert.pem", "key" => "/etc/hyper/key.pem"}
      }
    })

    config = Grpc.load()

    assert config.enabled == true
    assert config.port == 50_061
    assert %GRPC.Credential{ssl: ssl} = config.cred
    assert ssl[:certfile] == "/etc/hyper/cert.pem"
    assert ssl[:keyfile] == "/etc/hyper/key.pem"
  end

  test "a pre-built GRPC.Credential from config.exs passes through untouched" do
    cred = GRPC.Credential.new(ssl: [certfile: "/c.pem", keyfile: "/k.pem"])
    Application.put_env(:hyper, Grpc, cred: cred)

    assert Grpc.load().cred == cred
  end

  test "with no cred configured, load returns nil (plaintext)" do
    # The plaintext default: an absent cred must yield nil, never a defaulted
    # credential that would silently enable TLS.
    assert Grpc.load().cred == nil
  end

  test "server_options omits :cred and :adapter_opts at their plaintext defaults" do
    opts = Grpc.server_options(%Grpc{})

    assert opts[:endpoint] == Hyper.Grpc.Endpoint
    assert opts[:port] == 50_051
    refute Keyword.has_key?(opts, :cred)
    refute Keyword.has_key?(opts, :adapter_opts)
  end

  test "server_options carries a set credential and adapter options through" do
    cred = GRPC.Credential.new(ssl: [certfile: "/c.pem", keyfile: "/k.pem"])
    config = %Grpc{port: 50_061, cred: cred, adapter_opts: [ip: {0, 0, 0, 0}]}

    opts = Grpc.server_options(config)

    assert opts[:port] == 50_061
    assert opts[:cred] == cred
    assert opts[:adapter_opts] == [ip: {0, 0, 0, 0}]
  end
end
