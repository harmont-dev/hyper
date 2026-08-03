defmodule Hyper.Node.CordonTest do
  @moduledoc """
  The node's drain flag, and the two things about it that are easy to get wrong:

    * **reads answer the last write**, and a write that changes nothing is still
      a write whose answer must not change — a machine's controller re-asserts a
      cordon on a timer, so the no-op path is the common one;
    * **the flag does not outlive the process that owns it.** It is initialised
      when `Hyper.Node` starts and erased when it stops, so a fresh supervision
      tree never inherits a cordon from the previous one, and a node with no
      `Cordon` running reads as uncordoned. A leaked `true` here is silent and
      total: the node advertises `drain: true` forever, `NodeState.fits?/2`
      short-circuits to `false`, and it accepts no placements with no VM on it
      to explain why.
  """

  use ExUnit.Case, async: false

  alias Hyper.Node.Cordon

  # The flag is node-global by construction, so this suite is serial. It reuses
  # the node's own `Cordon` when one is running (`mix check` boots the full
  # tree; CI runs `mix test --no-start` and has none) and starts a `:temporary`
  # one otherwise, so that stopping it below stays stopped.
  setup do
    on_exit(fn -> if Process.whereis(Cordon), do: Cordon.set(false) end)
    %{cordon: ensure_cordon()}
  end

  test "reads report the last write, and re-asserting a cordon leaves it set" do
    refute Cordon.drained?()

    :ok = Cordon.set(true)
    assert Cordon.drained?()

    # The unchanged write is the path a machine's controller takes on every poll
    # as it re-asserts a cordon it already set: it is dropped before it reaches
    # the stored term, and it must not toggle what it re-asserts.
    :ok = Cordon.set(true)
    assert Cordon.drained?()

    :ok = Cordon.set(false)
    refute Cordon.drained?()
  end

  test "a cordon does not outlive the process that owns it", %{cordon: cordon} do
    :ok = Cordon.set(true)

    stop(cordon)

    # Both halves of the lifetime contract at once: the term is erased on the
    # way out, and a node with nothing owning it reads as uncordoned rather than
    # raising. (Where the application supervises `Cordon`, its restart reaches
    # the same answer through `init/1` — this is the run under `--no-start`
    # that proves `terminate/2` is doing it.)
    refute Cordon.drained?()
  end

  test "a restarted cordon comes back uncordoned, not remembering", %{cordon: cordon} do
    :ok = Cordon.set(true)
    stop(cordon)

    _restarted = ensure_cordon()

    # A rebooted machine is schedulable again by design: after a restart nothing
    # here can know whether the intent behind the cordon still stands, so
    # re-asserting is the watcher's job — `Hyper.Cluster.Fleet.Machine` polls.
    refute Cordon.drained?()
  end

  defp ensure_cordon do
    case Process.whereis(Cordon) do
      nil ->
        start_supervised!(%{id: Cordon, start: {Cordon, :start_link, [[]]}, restart: :temporary})

      pid ->
        pid
    end
  end

  defp stop(pid) do
    ref = Process.monitor(pid)
    :ok = GenServer.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
  end
end
