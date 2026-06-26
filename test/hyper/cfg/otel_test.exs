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
        proto: :http_protobuf,
        endpoint: "https://api.honeycomb.io",
        headers: %{"x-honeycomb-team" => "KEY"}
      )

    assert opts[:otlp_protocol] == :http_protobuf
    assert opts[:otlp_endpoint] == "https://api.honeycomb.io"
    assert opts[:otlp_headers] == [{"x-honeycomb-team", "KEY"}]
  end

  test "reads [otel] toml when config.exs is empty" do
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
