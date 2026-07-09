defmodule Hyper.Cfg.OtelTest do
  @moduledoc """
  Contract of OTLP exporter resolution: no endpoint in any source disables
  the exporter (`:none`, empty env var included); source order is
  config.exs > [otel] toml > OTEL_EXPORTER_OTLP_ENDPOINT; `proto` coerces to
  exactly `:grpc` or `:http_protobuf` (never a third value reaches the
  exporter); headers normalize to string pairs from map or keyword form.
  """
  use ExUnit.Case, async: false

  alias Hyper.Cfg.Otel
  alias Hyper.Cfg.Toml

  @env_var "OTEL_EXPORTER_OTLP_ENDPOINT"

  setup do
    original = System.get_env(@env_var)
    System.delete_env(@env_var)
    Toml.put_cache(%{})

    on_exit(fn ->
      if original, do: System.put_env(@env_var, original), else: System.delete_env(@env_var)
      Toml.reload()
    end)

    :ok
  end

  test "no endpoint in any source disables the exporter, empty env var included" do
    assert Otel.exporter_options([]) == :none

    System.put_env(@env_var, "")
    assert Otel.exporter_options([]) == :none
  end

  test "an endpoint alone gets the documented defaults: http_protobuf, no headers" do
    assert Otel.exporter_options(endpoint: "http://collector:4318") ==
             {:ok,
              [
                otlp_protocol: :http_protobuf,
                otlp_endpoint: "http://collector:4318",
                otlp_headers: []
              ]}
  end

  test "source precedence: config.exs > [otel] toml > env var" do
    System.put_env(@env_var, "http://env:1")
    assert {:ok, opts} = Otel.exporter_options([])
    assert opts[:otlp_endpoint] == "http://env:1"

    Toml.put_cache(%{"otel" => %{"endpoint" => "http://toml:2"}})
    assert {:ok, opts} = Otel.exporter_options([])
    assert opts[:otlp_endpoint] == "http://toml:2"

    assert {:ok, opts} = Otel.exporter_options(endpoint: "http://exs:3")
    assert opts[:otlp_endpoint] == "http://exs:3"
  end

  test "a full [otel] toml table maps through with proto and headers coerced" do
    Toml.put_cache(%{
      "otel" => %{
        "endpoint" => "https://api.honeycomb.io",
        "proto" => "grpc",
        "headers" => %{"x-honeycomb-team" => "key"}
      }
    })

    assert Otel.exporter_options([]) ==
             {:ok,
              [
                otlp_protocol: :grpc,
                otlp_endpoint: "https://api.honeycomb.io",
                otlp_headers: [{"x-honeycomb-team", "key"}]
              ]}
  end

  test "proto coercion: only grpc (atom or string) selects grpc, all else http_protobuf" do
    for {given, expected} <- [
          {:grpc, :grpc},
          {"grpc", :grpc},
          {:http_protobuf, :http_protobuf},
          {"http/protobuf", :http_protobuf},
          {"bogus", :http_protobuf}
        ] do
      assert {:ok, opts} = Otel.exporter_options(endpoint: "http://c:4318", proto: given)
      assert opts[:otlp_protocol] == expected, "proto #{inspect(given)}"
    end
  end

  test "headers accept keyword form, keys stringified" do
    assert {:ok, opts} = Otel.exporter_options(endpoint: "http://c:4318", headers: ["x-a": "1"])
    assert opts[:otlp_headers] == [{"x-a", "1"}]
  end
end
