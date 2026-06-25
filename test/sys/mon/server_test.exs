defmodule Sys.Mon.ServerTest do
  @moduledoc """
  Contract of the generic monitor process, driven through `sample_now/1` so the
  folding logic is exercised without depending on the real `Process.send_after`
  timer (which would make the test a sleep race).

  The properties pinned here are the ones a wrong `do_sample` would break:

    * an `:ok` reading updates `instant` and folds the EWMA; the *first* reading
      seeds the filter, so `smoothed == instant` (no warm-up ramp from zero);
    * a `:skip` leaves both `instant` and `smoothed` untouched -- the filter is
      not advanced and no spurious zero leaks in;
    * an `:error` leaves the whole reading untouched and does not crash the
      process (it is a transient, logged failure);
    * a later `:ok` smooths *toward* the new value (strictly between the old
      filtered value and the new sample), never jumping straight to it;
    * an `init/0` failure stops the process with that reason.

  Not async: the scripted sampler reads its queue from a named Agent, and the
  GenServer-lifecycle assertions are inherently sequential.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Sys.Mon.Server
  alias Sys.Mon.Server.Reading

  # A sampler whose readings are scripted: each `sample/1` pops the next step off
  # a named Agent queue. The sampler-private state is unused -- the queue is the
  # single source of truth, so successive `sample_now/1` calls walk the script.
  defmodule ScriptedSampler do
    @behaviour Sys.Mon.Sampler

    @queue __MODULE__.Queue

    @impl true
    def period, do: Unit.Time.ms(10)

    @impl true
    def tau, do: Unit.Time.ms(100)

    @impl true
    def init, do: {:ok, nil}

    @impl true
    def sample(_state) do
      step =
        Agent.get_and_update(@queue, fn
          [h | t] -> {h, t}
          [] -> {:skip, []}
        end)

      case step do
        {:ok, x} -> {:ok, x, nil}
        :skip -> {:skip, nil}
        {:error, r} -> {:error, r}
      end
    end
  end

  # A sampler that refuses to initialise, to exercise the `{:stop, reason}` path.
  defmodule BadInitSampler do
    @behaviour Sys.Mon.Sampler

    @impl true
    def period, do: Unit.Time.ms(10)
    @impl true
    def tau, do: Unit.Time.ms(100)
    @impl true
    def init, do: {:error, :no_baseline}
    @impl true
    def sample(state), do: {:skip, state}
  end

  # The server is started directly (not via Server.start_link/1) so there is no
  # module-name registration to collide between tests; we drive it by pid.
  setup do
    start_supervised!(%{
      id: ScriptedSampler.Queue,
      start: {Agent, :start_link, [fn -> [] end, [name: ScriptedSampler.Queue]]}
    })

    :ok
  end

  test "first :ok reading seeds the filter, so smoothed == instant" do
    Agent.update(ScriptedSampler.Queue, fn _ -> [{:ok, 0.5}] end)
    {:ok, pid} = GenServer.start_link(Server, ScriptedSampler)

    %Reading{instant: instant, smoothed: smoothed} = Server.sample_now(pid)

    assert instant == 0.5
    assert smoothed == 0.5
  end

  test ":skip leaves both instant and smoothed untouched" do
    Agent.update(ScriptedSampler.Queue, fn _ -> [{:ok, 0.5}, :skip] end)
    {:ok, pid} = GenServer.start_link(Server, ScriptedSampler)

    before = Server.sample_now(pid)
    after_skip = Server.sample_now(pid)

    assert after_skip == before
  end

  test ":error leaves the reading untouched and does not crash the process" do
    Agent.update(ScriptedSampler.Queue, fn _ -> [{:ok, 0.5}, {:error, :enoent}] end)
    {:ok, pid} = GenServer.start_link(Server, ScriptedSampler)

    before = Server.sample_now(pid)

    after_error =
      capture_log(fn ->
        send(self(), {:reading, Server.sample_now(pid)})
      end)

    assert_received {:reading, reading}
    assert reading == before
    assert Process.alive?(pid)
    assert after_error =~ "sample failed"
  end

  test "a later :ok smooths toward the new value, never jumping to it" do
    Agent.update(ScriptedSampler.Queue, fn _ -> [{:ok, 10.0}, {:ok, 0.0}] end)
    {:ok, pid} = GenServer.start_link(Server, ScriptedSampler)

    %Reading{smoothed: first} = Server.sample_now(pid)
    %Reading{instant: instant, smoothed: second} = Server.sample_now(pid)

    assert first == 10.0
    assert instant == 0.0
    # EWMA pulls toward 0.0 but cannot reach it in one finite step.
    assert second < first
    assert second > 0.0
  end

  test "value/1 before any sample is nil/nil" do
    Agent.update(ScriptedSampler.Queue, fn _ -> [] end)
    {:ok, pid} = GenServer.start_link(Server, ScriptedSampler)

    assert %Reading{instant: nil, smoothed: nil} = Server.value(pid)
  end

  test "an init/0 failure stops the process with that reason" do
    Process.flag(:trap_exit, true)
    assert {:error, :no_baseline} = GenServer.start_link(Server, BadInitSampler)
  end
end
