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

  test "builds a GRPC.Credential from a toml inline cert/key table" do
    Toml.put_cache(%{"grpc" => %{"cred" => %{"cert" => "/c.pem", "key" => "/k.pem"}}})
    assert match?(%GRPC.Credential{}, Grpc.load().cred)
  end
end
