defmodule Hyper.SuidHelper.DmsetupTest do
  @moduledoc """
  `test_system/0` reports two distinct failure shapes and one success. Kills a
  mutation that: treats a present-but-incomplete target set as OK; loses which
  targets are missing; or collapses the helper-failure classification into the
  missing-targets one.
  """
  use ExUnit.Case, async: false

  alias Hyper.SuidHelper.Dmsetup
  alias Hyper.Test.FakeSuidhelper

  test "is :ok when all required dm targets are present" do
    FakeSuidhelper.install!(~s|echo '{"output":"snapshot v1\\nthin v1\\nthin-pool v1"}'|)
    assert :ok = Dmsetup.test_system()
  end

  test "names exactly the missing required targets" do
    FakeSuidhelper.install!(~s|echo '{"output":"snapshot v1\\nthin v1"}'|)
    assert {:error, {:missing_dm_targets, ["thin-pool"]}} = Dmsetup.test_system()
  end

  test "classifies a helper failure as :dmsetup_targets_failed with code and message" do
    FakeSuidhelper.install!(~s|echo "control open failed"; exit 5|)
    assert {:error, {:dmsetup_targets_failed, 5, "control open failed"}} = Dmsetup.test_system()
  end
end
