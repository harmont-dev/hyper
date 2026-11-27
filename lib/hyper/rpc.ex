defmodule Hyper.Rpc do
  @moduledoc """
  `:erpc` calls that stay in the caller's trace.

  `:erpc.call/5` runs the function on another node in a fresh process, which
  starts with an empty OpenTelemetry context, so anything it traces opens a new
  trace instead of continuing the caller's. `call/5` carries the caller's trace
  context across as W3C trace-context headers, and `run/4` adopts it on the
  target before applying the function.

  `run/4` is the entry point for callers outside Hyper that reach it over
  `:erpc`: they pass `:otel_propagator_text_map.inject([])` as the carrier and
  call `run/4` in place of the function itself. A carrier with no trace context
  in it changes nothing: the function traces as it would have on its own.
  """

  @typedoc "W3C trace-context headers, as `:otel_propagator_text_map.inject/1` writes them."
  @type carrier :: [{String.t(), String.t()}]

  @doc """
  `:erpc.call(node, module, fun, args, timeout)`, run in the caller's trace.
  Returns and raises exactly as `:erpc.call/5` does.
  """
  @spec call(node(), module(), atom(), [term()], timeout()) :: term()
  def call(node, module, fun, args, timeout \\ :infinity) do
    carrier = :otel_propagator_text_map.inject([])
    :erpc.call(node, __MODULE__, :run, [carrier, module, fun, args], timeout)
  end

  @doc """
  Apply `module.fun(args)` in the trace `carrier` names, so its spans are
  children of the span that injected it.
  """
  @spec run(carrier(), module(), atom(), [term()]) :: term()
  def run(carrier, module, fun, args) do
    token = :otel_propagator_text_map.extract(carrier)

    try do
      apply(module, fun, args)
    after
      :otel_ctx.detach(token)
    end
  end
end
