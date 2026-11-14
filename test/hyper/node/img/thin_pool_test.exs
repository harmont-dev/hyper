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

  test "the pool's scratch dir is 0700 and its backing files 0600, fresh or reused", %{tmp: tmp} do
    original = Hyper.Cfg.Toml.reload()
    Hyper.Cfg.Toml.put_cache(Map.put(original, "work_dir", tmp))
    on_exit(fn -> Hyper.Cfg.Toml.put_cache(original) end)

    SuidHelperStub.install!(
      tmp,
      ~s(echo '{"result":"created","device":"/dev/mapper/hyper-thinpool","loops":{"metadata":"/dev/loop3"}}')
    )

    scratch = Hyper.Cfg.Dirs.scratch_dir()
    files = Enum.map(["thinpool.meta", "thinpool.data"], &Path.join(scratch, &1))
    mode = fn path -> Bitwise.band(File.stat!(path).mode, 0o7777) end

    for reused_mode <- [nil, 0o664] do
      if reused_mode, do: Enum.each(files, &File.chmod!(&1, reused_mode))

      assert {:ok, %ThinPool.State{meta_loop: "/dev/loop3"}} =
               Task.await(Task.async(fn -> ThinPool.init([]) end))

      assert mode.(scratch) == 0o700
      assert Enum.map(files, mode) == [0o600, 0o600]
    end
  end
end
