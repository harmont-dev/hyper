defmodule Hyper.SuidHelper.RequestContractTest do
  use ExUnit.Case, async: false

  alias Hyper.Node.FireVMM
  alias Hyper.Node.FireVMM.Jailer
  alias Hyper.SuidHelper
  alias Hyper.Test.SuidHelperStub

  @fixture Path.expand("../../../native/suidhelper/tests/fixtures/requests.json", __DIR__)
  @external_resource @fixture

  @vm_id "v1"

  setup do
    tmp = Path.join(System.tmp_dir!(), "request-contract-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    if reaper = Process.whereis(Hyper.Node.Reaper) do
      :ok = :sys.suspend(reaper)
      on_exit(fn -> :sys.resume(reaper) end)
    end

    Hyper.Cfg.Toml.put_cache(%{
      "tools" => %{
        "firecracker" => "/usr/local/bin/firecracker",
        "jailer" => "/usr/local/bin/jailer"
      }
    })

    on_exit(fn -> Hyper.Cfg.Toml.reload() end)

    %{tmp: tmp}
  end

  defp rows do
    %{
      "vm_launch" => {nil, fn -> Jailer.command(launch_opts(), "/dev/mapper/hyper-v1") end},
      "vm_claim_api_socket" =>
        {~s({"result":"claimed"}), fn -> SuidHelper.Vm.claim_api_socket(@vm_id) end},
      "vm_claim_vsock_socket" =>
        {~s({"result":"claimed"}), fn -> SuidHelper.Vm.claim_vsock_socket(@vm_id) end},
      "vm_teardown" => {~s({"result":"tore_down"}), fn -> SuidHelper.Vm.teardown(@vm_id) end},
      "img_activate" =>
        {~s({"result":"activated","device":"/dev/mapper/hyper-img-x","names":[]}),
         fn ->
           SuidHelper.Img.activate("hyper-img-x", "/srv/hyper/base.img", ["/srv/hyper/d1.img"])
         end},
      "thin_pool_create" =>
        {~s({"result":"created","device":"/dev/mapper/hyper-pool","loops":{"metadata":"/dev/loop3"}}),
         fn ->
           SuidHelper.Thin.create_pool("hyper-pool", "/srv/hyper/meta", "/srv/hyper/data", 128, 0)
         end},
      "dm_remove" => {~s({"result":"removed"}), fn -> SuidHelper.Dmsetup.remove("hyper-v1") end},
      "thin_volume_create" =>
        {~s({"result":"created","device":"/dev/mapper/hyper-v1"}),
         fn ->
           SuidHelper.Thin.create_volume(
             "hyper-pool",
             1,
             "hyper-v1",
             "/dev/mapper/hyper-img",
             nil
           )
         end},
      "thin_volume_create_forked" =>
        {~s({"result":"created","device":"/dev/mapper/hyper-v2"}),
         fn ->
           SuidHelper.Thin.create_volume(
             "hyper-pool",
             2,
             "hyper-v2",
             "/dev/mapper/hyper-img",
             "hyper-v1"
           )
         end},
      "thin_destroy" =>
        {~s({"result":"destroyed"}), fn -> SuidHelper.Thin.destroy("hyper-pool", "hyper-v1") end},
      "thin_fork_delta" =>
        {~s({"scanned_chunks":1,"written_chunks":1}),
         fn ->
           SuidHelper.ForkDelta.run(
             "hyper-pool",
             "/dev/loop3",
             "hyper-v1",
             9,
             "/dev/mapper/hyper-img",
             "/srv/hyper/cow.img"
           )
         end},
      "host_init" =>
        {~s({"result":"host_ready","hyper_base":"/srv/hyper"}), fn -> SuidHelper.host_init() end},
      "version" =>
        {~s({"version":"0","checksum_blake3":"0"}), fn -> SuidHelper.verify_version() end}
    }
  end

  test "every request the helper accepts has an Elixir builder, and vice versa" do
    assert Enum.sort(Map.keys(rows())) == Enum.sort(Map.keys(fixture()))
  end

  test "every Elixir builder sends the fields and JSON types the helper's fixture pins",
       %{tmp: tmp} do
    for {name, expected} <- fixture() do
      {stdout, build} = Map.fetch!(rows(), name)
      sent = sent_request(tmp, stdout, build)

      assert shape(sent) == shape(expected), "#{name}: sent #{inspect(sent)}"
    end
  end

  defp sent_request(_tmp, nil, build) do
    %{args: [json]} = build.()
    Jason.decode!(json)
  end

  defp sent_request(tmp, stdout, build) do
    record = Path.join(tmp, "request.json")
    SuidHelperStub.install!(tmp, ~s(printf '%s' "$1" > "#{record}"\necho '#{stdout}'))
    _ = build.()
    record |> File.read!() |> Jason.decode!()
  end

  defp shape(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, shape(v)} end)
  defp shape(list) when is_list(list), do: list |> Enum.map(&shape/1) |> Enum.uniq()
  defp shape(value) when is_binary(value), do: :string
  defp shape(value) when is_integer(value), do: :integer
  defp shape(value) when is_boolean(value), do: :boolean
  defp shape(nil), do: nil

  defp fixture, do: @fixture |> File.read!() |> Jason.decode!()

  defp launch_opts do
    %FireVMM.Opts{
      vm_id: @vm_id,
      uid: 900_001,
      gid: 900_001,
      type: :micro,
      arch: :x86_64,
      mutable: nil,
      kernel: "/srv/hyper/vmlinux",
      boot_args: nil
    }
  end
end
