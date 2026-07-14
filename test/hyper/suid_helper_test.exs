defmodule Hyper.SuidHelperTest do
  @moduledoc """
  Contracts for the helper front door. Kills mutations that would: swallow a
  helper failure in `sys_test/0`; skip a lifecycle step in `test_system/0`;
  invert the version/checksum comparison in `verify_version/0` (accepting a
  stale binary, or rejecting the right one); or stop reporting a missing binary
  in `helper_present/0`.
  """
  use ExUnit.Case, async: false

  alias Hyper.SuidHelper
  alias Hyper.SuidHelper.Expected
  alias Hyper.Test.FakeSuidhelper

  # A fake that answers `version` with the identity this build expects and
  # `dmsetup targets` with all three required targets, so the whole
  # test_system/0 chain is green.
  defp healthy_body do
    """
    case "$1" in
      "version")
        echo '{"version":"#{Expected.version()}","checksum_blake3":"#{Expected.checksum_blake3()}"}'
        ;;
      "dmsetup")
        case "$2" in
          "targets")
            echo '{"output":"snapshot v1.0.0\\nthin v1.0.0\\nthin-pool v1.0.0"}'
            ;;
        esac
        ;;
      *) echo '{}' ;;
    esac
    """
  end

  describe "sys_test/0" do
    test "returns the helper's compiled-in base on success" do
      FakeSuidhelper.install!(~s|echo '{"hyper_base":"/srv/hyper"}'|)
      assert {:ok, "/srv/hyper"} = SuidHelper.sys_test()
    end

    test "propagates a helper failure" do
      FakeSuidhelper.install!(~s|echo "cannot promote"; exit 1|)
      assert {:error, {1, "cannot promote"}} = SuidHelper.sys_test()
    end
  end

  describe "verify_version/0" do
    test "accepts the exact expected version and checksum" do
      FakeSuidhelper.install!(healthy_body())
      assert :ok = SuidHelper.verify_version()
    end

    test "rejects a mismatched checksum as :version_mismatch" do
      FakeSuidhelper.install!(
        ~s|echo '{"version":"#{Expected.version()}","checksum_blake3":"deadbeef"}'|
      )

      assert {:error, :version_mismatch} = SuidHelper.verify_version()
    end

    test "propagates a helper failure rather than reporting a mismatch" do
      FakeSuidhelper.install!(~s|echo "no such subcommand"; exit 2|)
      assert {:error, {2, "no such subcommand"}} = SuidHelper.verify_version()
    end
  end

  describe "test_system/0" do
    test "is :ok when the binary is present, versioned, and the dm targets exist" do
      FakeSuidhelper.install!(healthy_body())
      assert :ok = SuidHelper.test_system()
    end

    test "stops at the version check when the binary is the wrong build" do
      FakeSuidhelper.install!(~s|echo '{"version":"9.9.9","checksum_blake3":"x"}'|)
      assert {:error, :version_mismatch} = SuidHelper.test_system()
    end
  end

  describe "helper_present/0 (via test_system/0)" do
    test "reports the binary missing when the configured path does not exist" do
      Hyper.Cfg.Toml.put_cache(%{"tools" => %{"suidhelper" => "/nonexistent/hyper-suidhelper"}})
      on_exit(fn -> Hyper.Cfg.Toml.reload() end)
      assert {:error, :suid_helper_not_found} = SuidHelper.test_system()
    end
  end
end
