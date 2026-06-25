defmodule Hyper.VmOtelTest do
  # Proves the span-capture harness works against an already-instrumented
  # function (Hyper.Vm.fast_fork). If this fails, every later span test is
  # untrustworthy — fix the harness here first.
  use Hyper.OtelCase

  test "fast_fork/1 emits the Hyper.Vm.fast_fork span" do
    assert {:error, :not_implemented} = Hyper.Vm.fast_fork(self())
    assert_receive {:span, span(name: "Hyper.Vm.fast_fork")}, 1_000
  end
end
