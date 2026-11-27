defmodule Hyper.RpcTest do
  @moduledoc """
  `Hyper.Rpc` promises three things: the function it runs over `:erpc` joins
  the caller's trace under the caller's span; `run/4` leaves the context of
  the process it runs in as it found it; and failures surface exactly as
  `:erpc.call/5` raises them, which every caller's `catch` matches on.

  `:erpc` runs a call to the local node with no timeout in the calling process,
  context and all, so these calls give one: that runs them in a process of their
  own, as a call to another node always is.
  """
  use ExUnit.Case, async: true

  require OpenTelemetry.Tracer, as: Tracer

  @timeout_ms 5_000

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:opentelemetry)
    :ok
  end

  test "the function runs in the caller's trace, under the caller's span" do
    Tracer.with_span "caller" do
      caller = Tracer.current_span_ctx()
      callee = Hyper.Rpc.call(node(), :otel_tracer, :current_span_ctx, [], @timeout_ms)

      assert :otel_span.is_valid(caller)
      assert :otel_span.trace_id(callee) == :otel_span.trace_id(caller)
      assert :otel_span.span_id(callee) == :otel_span.span_id(caller)
    end
  end

  test "without a trace to join, the function starts none" do
    callee = Hyper.Rpc.call(node(), :otel_tracer, :current_span_ctx, [], @timeout_ms)

    refute :otel_span.is_valid(callee)
  end

  test "run/4 leaves the calling process's context as it found it" do
    carrier = Tracer.with_span("elsewhere", do: :otel_propagator_text_map.inject([]))
    before = :otel_ctx.get_current()

    Hyper.Rpc.run(carrier, :otel_tracer, :current_span_ctx, [])

    assert :otel_ctx.get_current() == before
  end

  test "a raise in the function reaches the caller as :erpc.call/5 raises it" do
    expected = catch_error(:erpc.call(node(), :erlang, :error, [:boom], @timeout_ms))
    got = catch_error(Hyper.Rpc.call(node(), :erlang, :error, [:boom], @timeout_ms))

    assert {:exception, :boom, _stack} = expected
    assert {:exception, :boom, _stack} = got
  end
end
