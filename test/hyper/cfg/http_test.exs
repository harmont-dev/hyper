defmodule Hyper.Cfg.HttpTest do
  @moduledoc """
    test: TOML coercion, pass-through, plaintext default.
  """
  use ExUnit.Case, async: false

  alias Hyper.Cfg.Http
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

  test "an [http_server] toml tables loads each key value pairing correctly" do
    Toml.put_cache(%{
      "http_server" => %{
        "enabled" => true,
        "port" => 8080,
        "options" => %{"ip" => "127.0.0.2"}
      }
    })

    config = Http.load()

    assert config.enabled == true
    assert config.port == 8080

    %{"ip" => ip} = config.http_server_opts
    assert ip == "127.0.0.2"
  end

  test "server_options adds default values when Http Config is empty" do
    server_options = Http.server_options(%Http{})

    assert server_options[:options][:ip] == {127, 0, 0, 1}
    assert server_options[:options][:port] == 8081
  end

  test "config carries server options through" do
    config = %Http{port: 8082, http_server_opts: [ip: {0, 0, 0, 1}]}

    opts = Http.server_options(config)

    assert opts[:options][:port] == 8082
    assert opts[:options][:ip] == {0, 0, 0, 1}
  end
end
