defmodule Hyper.OtelCase do
  @moduledoc """
  ExUnit case template for asserting OpenTelemetry spans.

  `use Hyper.OtelCase` ensures `:opentelemetry` is running with the synchronous
  (simple) span processor and routes the pid exporter at the test process, so
  finished spans arrive as `{:span, span(...)}` messages assertable with
  `assert_receive`. The `span/1` record macro (extracted from opentelemetry's
  header) is imported for matching on `name:` / `attributes:`.

  Runs under `mix test --no-start`: it starts `:opentelemetry` itself rather
  than relying on the full app supervisor (which cannot boot without
  Firecracker/Postgres). These cases are NOT async — the exporter is
  process-global tracer state.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      require Record

      Record.defrecordp(
        :span,
        Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
      )
    end
  end

  setup do
    # config/config.exs already pins :simple in :test; set it here too so the
    # harness is correct even when :opentelemetry is started by --no-start.
    Application.put_env(:opentelemetry, :span_processor, :simple)
    Application.put_env(:opentelemetry, :traces_exporter, :none)
    {:ok, _} = Application.ensure_all_started(:opentelemetry)
    # Deliver finished spans to this (sync) test process.
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    :ok
  end
end
