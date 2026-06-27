defmodule Hyper.Cfg.OtelTest do
  use ExUnit.Case, async: false

  alias Hyper.Cfg.Otel
  alias Hyper.Cfg.Toml

  setup do
    Toml.put_cache(%{})
    on_exit(fn -> Toml.reload() end)
    :ok
  end

  test "config.exs proto/endpoint/headers produce opentelemetry_exporter opts" do
    {:ok, opts} =
      Otel.exporter_options(
        proto: :grpc,
        endpoint: "https://otel.example.com:4317",
        headers: %{"authorization" => "Bearer xyz"}
      )

    assert opts[:otlp_protocol] == :grpc
    assert opts[:otlp_endpoint] == "https://otel.example.com:4317"
    assert opts[:otlp_headers] == [{"authorization", "Bearer xyz"}]
  end

  test "reads [otel] toml when config.exs is empty; string proto becomes an atom" do
    Toml.put_cache(%{
      "otel" => %{"proto" => "http_protobuf", "endpoint" => "http://collector:4318"}
    })

    {:ok, opts} = Otel.exporter_options([])
    assert opts[:otlp_protocol] == :http_protobuf
    assert opts[:otlp_endpoint] == "http://collector:4318"
    assert opts[:otlp_headers] == []
  end

  test ":none when no endpoint anywhere" do
    assert Otel.exporter_options([]) == :none
  end
end
