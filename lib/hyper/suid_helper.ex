defmodule Hyper.SuidHelper do
  @moduledoc """
  Interface to the setuid-root device helper (`hyper-suidhelper`), split by tool:

    * `Hyper.SuidHelper.Losetup`    - loop devices
    * `Hyper.SuidHelper.Dmsetup`    - device-mapper (snapshot / thin)
    * `Hyper.SuidHelper.Blockdev`   - block-device queries
    * `Hyper.SuidHelper.ChrootJail` - chroot lifecycle (prepare / remove)

  Elixir runs unprivileged; these submodules are the only path to the privileged operations. Each
  builds the argv for one operation and shells the helper through `exec/1`, which decodes the
  JSON the helper prints on success. The helper validates every argument before briefly
  escalating to root (see `native/suidhelper`).

  `test_system/0` aggregates each tool's own presence check; `sys_test/0` runs the helper's
  self-test and reports the base path it was compiled against.
  """

  alias Hyper.SuidHelper.{Blockdev, Dmsetup, Expected, Losetup}

  use OpenTelemetryDecorator

  @typedoc "Error tuple: exit code + trimmed stderr/stdout from the helper."
  @type err :: {non_neg_integer(), String.t()}

  @doc false
  # Run the helper with `argv`. Returns `{:ok, decoded_json}` on exit 0,
  # `{:error, {code, message}}` otherwise. Shared transport for the tool
  # submodules; not part of the public API.
  @spec exec([String.t()]) :: {:ok, map()} | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.exec", include: [:argv])
  def exec(argv) do
    case System.cmd(Hyper.Cfg.Tools.suidhelper(), argv, stderr_to_stdout: true) do
      {out, 0} -> {:ok, Jason.decode!(out)}
      {out, code} -> {:error, {code, String.trim(out)}}
    end
  end

  @doc """
  Run the helper's `sys-test` subcommand (proves it can promote to root). Returns
  `{:ok, hyper_base}` where `hyper_base` is the work-dir the helper was compiled
  against.
  """
  @spec sys_test() :: {:ok, Path.t()} | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.sys_test")
  def sys_test do
    case exec(["sys-test"]) do
      {:ok, %{"hyper_base" => base}} -> {:ok, base}
      {:error, _} = err -> err
    end
  end

  @doc """
  Check that the setuid helper and every tool it execs are usable on this
  machine: the helper binary is present, is the build this release expects
  (`verify_version/0`), then each tool submodule's own check.
  """
  @spec test_system() :: :ok | {:error, term()}
  @decorate with_span("Hyper.SuidHelper.test_system")
  def test_system do
    with :ok <- helper_present(),
         :ok <- verify_version(),
         :ok <- Losetup.test_system(),
         :ok <- Dmsetup.test_system() do
      Blockdev.test_system()
    end
  end

  @doc """
  Check the deployed helper is the one this build produced: its `version` output
  must match `Hyper.SuidHelper.Expected` (the identity captured from the stamped
  binary at compile time). Catches a stale or wrong binary at the configured path.

  This compares the helper's *self-reported* identity, so it is a build-provenance
  check, not an adversarial tamper proof -- a malicious binary could report any
  value.
  """
  @spec verify_version() :: :ok | {:error, :version_mismatch | err()}
  @decorate with_span("Hyper.SuidHelper.verify_version")
  def verify_version do
    case exec(["version"]) do
      {:ok, %{"version" => v, "checksum_blake3" => c}} ->
        if v == Expected.version() and c == Expected.checksum_blake3(),
          do: :ok,
          else: {:error, :version_mismatch}

      {:error, _} = err ->
        err
    end
  end

  @spec helper_present() :: :ok | {:error, :suid_helper_not_found}
  defp helper_present do
    if System.find_executable(Hyper.Cfg.Tools.suidhelper()),
      do: :ok,
      else: {:error, :suid_helper_not_found}
  end
end
