defmodule Hyper.Node.Img.ThinPoolTest do
  use ExUnit.Case, async: false

  alias Hyper.Node.Img.ThinPool
  alias Hyper.Test.SuidHelperStub

  @failing "echo 'dmsetup failed' >&2; exit 2"

  setup do
    tmp = Path.join(System.tmp_dir!(), "thin-pool-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    if reaper = Process.whereis(Hyper.Node.Reaper) do
      :ok = :sys.suspend(reaper)
      on_exit(fn -> :sys.resume(reaper) end)
    end

    %{tmp: tmp}
  end

  test "an id goes back to the pool only once the helper confirmed it is gone", %{tmp: tmp} do
    rows = [
      {"destroy fails", {:destroy, "hyper-v1", 5}, @failing, []},
      {"destroy succeeds", {:destroy, "hyper-v1", 5}, ~s(echo '{"result":"destroyed"}'), [5]},
      {"create fails", {:create_volume, "hyper-v1", "/dev/mapper/hyper-img", "hyper-v0"},
       @failing, []},
      {"fork failed", {:release_scratch, 5, {:error, {2, "boom"}}}, @failing, []},
      {"fork succeeded", {:release_scratch, 5, {:ok, %{scanned: 1, written: 1}}}, @failing, [5]}
    ]

    for {label, request, helper, freed} <- rows do
      SuidHelperStub.install!(tmp, helper)

      {:reply, _, state} =
        ThinPool.handle_call(request, {self(), make_ref()}, %ThinPool.State{
          meta_loop: "/dev/loop3",
          next: 6
        })

      assert state.freed == freed, label
    end
  end
end
