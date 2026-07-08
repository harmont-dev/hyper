defmodule Hyper.E2e.ForkTest do
  @moduledoc """
  Live end-to-end contract of VM forking on a provisioned host:

  - `Hyper.Vm.fast_fork/1` boots a sibling that sees the parent's pre-fork
    writes (the thin snapshot is a true point-in-time disk copy);
  - parent and child then diverge independently (COW isolation: a post-fork
    write in one is invisible to the other);
  - `Hyper.Node.publish_fork_image/1` records a derived image whose chain is
    the parent's base plus one `:delta` blob;
  - a VM created from the derived image composes that chain (dm-snapshot over
    the published COW store) and boots with the parent's pre-publish state —
    including the parent's writes, excluding the child's;
  - all forked writable volumes are reclaimed on stop (no dm leak).

  Runs only under `--only integration` / `--include integration` on a host
  provisioned per docs/cookbook/install.md (CI: the `integration` job).
  """
  use ExUnit.Case, async: false

  import Hyper.E2e

  @moduletag :integration
  @moduletag timeout: :timer.minutes(10)

  # public.ecr.aws mirrors library images without Docker Hub's per-IP pull
  # limits, which shared GHA egress IPs routinely exhaust.
  @image System.get_env("HYPER_E2E_IMAGE", "public.ecr.aws/docker/library/alpine:3.19")

  test "fast_fork isolates writes; published delta composes and boots" do
    assert {:ok, img_id} = Hyper.Img.OciLoader.load(@image)

    assert {:ok, parent} = Hyper.create_vm(%Hyper.Vm.Spec{img_id: img_id, type: :micro})
    on_exit(fn -> Hyper.Node.stop_image_vm(parent) end)

    # First exec after a boot gets 3 minutes: later guests of a run have come
    # up slower than the first on nested-virt CI runners (see crash_recovery).
    assert {:ok, %{exit_code: 0}} =
             await_exec(
               parent,
               ["/bin/sh", "-c", "echo prefork > /marker && sync"],
               :timer.minutes(3)
             )

    assert {:ok, child} = Hyper.Vm.fast_fork(parent)
    on_exit(fn -> Hyper.Node.stop_image_vm(child) end)

    child_id = Hyper.id(child)
    assert child_id, "Hyper.id/1 returned nil for a freshly-forked VM"
    child_rw = Hyper.Node.Img.Mutable.dm_name(child_id)

    # The snapshot is a point-in-time copy: the pre-fork write is visible.
    assert {:ok, %{stdout: seen, exit_code: 0}} =
             await_exec(child, ["/bin/cat", "/marker"], :timer.minutes(3))

    assert seen =~ "prefork"

    # COW isolation, both directions: post-fork writes do not cross.
    assert {:ok, %{exit_code: 0}} =
             await_exec(child, ["/bin/sh", "-c", "echo childwrite > /childfile && sync"])

    assert {:ok, %{exit_code: 0}} =
             await_exec(parent, ["/bin/sh", "-c", "echo parentwrite > /parentfile && sync"])

    assert {:ok, %{exit_code: parent_sees_childfile}} =
             await_exec(parent, ["/bin/cat", "/childfile"])

    assert parent_sees_childfile != 0, "child's post-fork write leaked into the parent"

    assert {:ok, %{exit_code: child_sees_parentfile}} =
             await_exec(child, ["/bin/cat", "/parentfile"])

    assert child_sees_parentfile != 0, "parent's post-fork write leaked into the child"

    # Publish the parent's divergence (pre-fork marker + /parentfile, no
    # /childfile) as a derived image while the parent is still running.
    parent_id = Hyper.id(parent)
    assert {:ok, %{img_id: derived}} = Hyper.Node.publish_fork_image(parent_id)

    assert [base, delta] = Hyper.Img.Db.Image.resolve_chain(derived)
    assert base.kind == :base
    assert delta.kind == :delta

    # Free the budget (2 VMs is the node's ceiling) and prove reclaim before
    # booting from the derived image.
    assert :ok = Hyper.Node.stop_image_vm(child)

    assert poll_until(fn -> not MapSet.member?(dm_devices(), child_rw) end, :timer.seconds(90)),
           "forked child's writable dm volume #{child_rw} leaked after stop_image_vm"

    assert :ok = Hyper.Node.stop_image_vm(parent)

    # A fresh VM from the derived image composes [base, delta] and carries the
    # parent's published state — and none of the child's.
    assert {:ok, cousin} = Hyper.create_vm(%Hyper.Vm.Spec{img_id: derived, type: :micro})
    on_exit(fn -> Hyper.Node.stop_image_vm(cousin) end)

    assert {:ok, %{stdout: marker, exit_code: 0}} =
             await_exec(cousin, ["/bin/cat", "/marker"], :timer.minutes(3))

    assert marker =~ "prefork"

    assert {:ok, %{stdout: pw, exit_code: 0}} = await_exec(cousin, ["/bin/cat", "/parentfile"])
    assert pw =~ "parentwrite"

    assert {:ok, %{exit_code: cousin_sees_childfile}} =
             await_exec(cousin, ["/bin/cat", "/childfile"])

    assert cousin_sees_childfile != 0, "child's writes leaked into the published delta"
  end
end
