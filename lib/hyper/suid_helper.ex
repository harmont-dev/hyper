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

  alias Hyper.Node.Net.Ip.Host
  alias Hyper.SuidHelper.Expected

  use OpenTelemetryDecorator

  @dm_target_modules ~w(dm_mod dm_snapshot dm_thin_pool)

  @typedoc "Error tuple: exit code + trimmed stderr/stdout from the helper."
  @type err :: {non_neg_integer(), String.t()}

  @doc false
  # Run the helper with `request` as its single JSON argument. Returns
  # `{:ok, decoded_json}` on exit 0, `{:error, {code, message}}` otherwise.
  # Shared transport for the tool submodules; not part of the public API.
  @spec exec(%{required(:op) => String.t(), optional(atom()) => term()}) ::
          {:ok, map()} | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.exec", include: [:request])
  def exec(request) do
    case System.cmd(Hyper.Cfg.Tools.suidhelper(), argv(request), stderr_to_stdout: true) do
      {out, 0} -> decode(out)
      {out, code} -> {:error, {code, String.trim(out)}}
    end
  end

  @spec decode(String.t()) :: {:ok, map()} | {:error, err()}
  defp decode(out) do
    case Jason.decode(out) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:error, {0, String.trim(out)}}
    end
  end

  @doc false
  @spec argv(%{required(:op) => String.t(), optional(atom()) => term()}) :: [String.t()]
  def argv(request), do: [Jason.encode!(request)]

  @doc """
  Check that the setuid helper is usable on this machine: the helper binary is
  present, is the build this release expects (`verify_version/0`), and the kernel
  exposes the device-mapper targets we need (`Dmsetup.test_system/0`, which also
  exercises the helper's configured `dmsetup` binary).

  The `losetup` binary is validated by the helper the first time it is used; its
  path lives in the helper's own config, not here.
  """
  @spec test_system() :: :ok | {:error, term()}
  @decorate with_span("Hyper.SuidHelper.test_system")
  def test_system do
    with :ok <- helper_present(),
         :ok <- verify_version() do
      dm_targets_present()
    end
  end

  @spec host_init() ::
          {:ok, Path.t(), Host.t()} | {:error, err() | {:malformed_host_net, term()}}
  @decorate with_span("Hyper.SuidHelper.host_init")
  def host_init do
    %{op: "host_init"} |> exec() |> host_ready()
  end

  @spec host_ready({:ok, map()} | {:error, err()}) ::
          {:ok, Path.t(), Host.t()} | {:error, err() | {:malformed_host_net, term()}}
  defp host_ready({:ok, %{"result" => "host_ready", "hyper_base" => base, "net" => net}}) do
    case host_net(net) do
      {:ok, host} -> {:ok, base, host}
      :error -> {:error, {:malformed_host_net, net}}
    end
  end

  defp host_ready({:error, _} = err), do: err

  @spec host_net(term()) :: {:ok, Host.t()} | :error
  defp host_net(%{"uplink" => uplink, "transit_prefix" => transit, "vm_prefix" => vm})
       when is_binary(uplink) do
    with {:ok, transit} <- prefix(transit, &:inet.parse_ipv4strict_address/1),
         {:ok, vm} <- prefix(vm, &:inet.parse_ipv6strict_address/1) do
      {:ok, %Host{uplink: uplink, transit_prefix: transit, vm_prefix: vm}}
    end
  end

  defp host_net(_net), do: :error

  @spec prefix(term(), (charlist() -> {:ok, :inet.ip_address()} | {:error, :einval})) ::
          {:ok, Host.prefix()} | :error
  defp prefix(cidr, parse) when is_binary(cidr) do
    with [addr, len] <- String.split(cidr, "/"),
         {len, ""} <- Integer.parse(len),
         {:ok, addr} <- parse.(String.to_charlist(addr)) do
      {:ok, {addr, len}}
    else
      _ -> :error
    end
  end

  defp prefix(_cidr, _parse), do: :error

  @spec dm_targets_present() :: :ok | {:error, {:missing_dm_targets, [String.t()]}}
  defp dm_targets_present do
    case Sys.Linux.Dm.missing_modules(@dm_target_modules) do
      [] -> :ok
      missing -> {:error, {:missing_dm_targets, missing}}
    end
  end

  @doc """
  Check the deployed helper is the one this build produced: its `version` output
  must match the identity captured from the stamped binary at compile time.
  Catches a stale or wrong binary at the configured path.

  This compares the helper's *self-reported* identity, so it is a build-provenance
  check, not an adversarial tamper proof -- a malicious binary could report any
  value.
  """
  @spec verify_version() :: :ok | {:error, :version_mismatch | err()}
  @decorate with_span("Hyper.SuidHelper.verify_version")
  def verify_version do
    case exec(%{op: "version"}) do
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
