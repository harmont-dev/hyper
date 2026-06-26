defmodule Hyper.Cfg.FacadesTest do
  use ExUnit.Case, async: false

  test "Cluster.topologies reads :libcluster app env" do
    assert is_list(Hyper.Cfg.Cluster.topologies())
  end

  test "Db.repo_opts reads the Ecto repo config" do
    assert Keyword.keyword?(Hyper.Cfg.Db.repo_opts())
  end

  test "Telemetry.exporter reflects the configured traces_exporter" do
    prior = Application.get_env(:opentelemetry, :traces_exporter)

    on_exit(fn ->
      if prior == nil,
        do: Application.delete_env(:opentelemetry, :traces_exporter),
        else: Application.put_env(:opentelemetry, :traces_exporter, prior)
    end)

    Application.put_env(:opentelemetry, :traces_exporter, :none)
    assert Hyper.Cfg.Telemetry.exporter() == :none
  end

  test "Telemetry.otlp_endpoint reads the configured endpoint" do
    prior = Application.get_env(:opentelemetry_exporter, :otlp_endpoint)

    on_exit(fn ->
      if prior == nil,
        do: Application.delete_env(:opentelemetry_exporter, :otlp_endpoint),
        else: Application.put_env(:opentelemetry_exporter, :otlp_endpoint, prior)
    end)

    Application.put_env(:opentelemetry_exporter, :otlp_endpoint, "http://x:4318")
    assert Hyper.Cfg.Telemetry.otlp_endpoint() == "http://x:4318"
  end
end
