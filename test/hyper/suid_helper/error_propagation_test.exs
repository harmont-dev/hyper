defmodule Hyper.SuidHelper.ErrorPropagationTest do
  @moduledoc """
  Error contract for every tool wrapper: a nonzero helper exit is surfaced as
  `{:error, {code, message}}`, never swallowed into `:ok`/`{:ok, _}` and never
  raised. Kills any mutation that drops or rewrites a failure arm — the arm most
  likely to be silently wrong, since the integration suite only ever exercises
  the success path.
  """
  use ExUnit.Case, async: false

  alias Hyper.SuidHelper.{Blockcopy, Blockdev, ChrootJail, Dmsetup, Losetup, Network, ThinDump}
  alias Hyper.Test.FakeSuidhelper

  # {label, module, function, args} — plain data so the compile-time `for` can
  # generate one test per row (an anonymous fn in a module attribute cannot be
  # Macro.escape/1'd; escapable data can).
  @wrappers [
    {"Losetup.attach_ro", Losetup, :attach_ro, ["/img"]},
    {"Losetup.attach_rw", Losetup, :attach_rw, ["/img"]},
    {"Losetup.detach", Losetup, :detach, ["/dev/loop0"]},
    {"Losetup.list", Losetup, :list, []},
    {"Blockdev.device_sectors", Blockdev, :device_sectors, ["/dev/loop0"]},
    {"Dmsetup.create_snapshot", Dmsetup, :create_snapshot, ["n", "/o", "/c", 8]},
    {"Dmsetup.create_thin_pool", Dmsetup, :create_thin_pool, ["n", "/m", "/d", 8, 128, 0]},
    {"Dmsetup.create_thin_external", Dmsetup, :create_thin_external, ["n", "/p", 1, 8, "/o"]},
    {"Dmsetup.create_snapshot_rw", Dmsetup, :create_snapshot_rw, ["n", "/o", "/c", 8]},
    {"Dmsetup.remove", Dmsetup, :remove, ["n"]},
    {"Dmsetup.suspend", Dmsetup, :suspend, ["n"]},
    {"Dmsetup.resume", Dmsetup, :resume, ["n"]},
    {"Dmsetup.message", Dmsetup, :message, ["n", "msg"]},
    {"Dmsetup.list", Dmsetup, :list, []},
    {"Dmsetup.test_system", Dmsetup, :test_system, []},
    {"ChrootJail.prepare", ChrootJail, :prepare, ["/root", "/k", "/dev/x", 900_100, 900_100]},
    {"ChrootJail.remove", ChrootJail, :remove, ["/root", "/cg"]},
    {"ChrootJail.grant_api", ChrootJail, :grant_api, ["/s"]},
    {"ChrootJail.grant_vsock", ChrootJail, :grant_vsock, ["/s"]},
    {"ThinDump.mappings", ThinDump, :mappings, ["/meta", 1]},
    {"Blockcopy.copy", Blockcopy, :copy,
     ["/src", "/dst", %{block_sectors: 128, ranges: [[0, 4]]}]},
    {"Network.prepare", Network, :prepare, ["vabc", 900_100]},
    {"Network.teardown", Network, :teardown, ["vabc", 900_100]},
    {"Network.teardown_orphan", Network, :teardown_orphan, ["vabc"]},
    {"Network.host_init", Network, :host_init, []}
  ]

  # Dmsetup.test_system wraps a helper failure as {:dmsetup_targets_failed, code, msg}
  # (its own classification); every other wrapper passes {code, message} straight
  # through. Assert the shape each wrapper actually promises.
  for {label, mod, fun, args} <- @wrappers do
    test "#{label} surfaces a nonzero helper exit" do
      FakeSuidhelper.install!(~s|echo "boom"; exit 7|)

      case apply(unquote(mod), unquote(fun), unquote(Macro.escape(args))) do
        {:error, {7, "boom"}} -> :ok
        {:error, {:dmsetup_targets_failed, 7, "boom"}} -> :ok
        other -> flunk("#{unquote(label)} swallowed the failure: #{inspect(other)}")
      end
    end
  end
end
