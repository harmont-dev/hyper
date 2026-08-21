defmodule Hyper.Provider.Gcp do
  @moduledoc """
  `Hyper.Provider` implementation backed by Google Compute Engine, driven by
  shelling out to the `gcloud` CLI.

  There is deliberately no REST client and no service-account JWT signing here:
  on the control node `gcloud` authenticates automatically through the VM's
  attached service account, so `System.cmd/3` is both the shortest and the only
  credential-free path to the Compute API.

  Workers are created with `--enable-nested-virtualization`, without which
  `/dev/kvm` does not exist inside the guest and Firecracker — the entire point
  of a worker — cannot start. They are labelled `hyper-role=worker`, which is
  also the filter `c:list_nodes/1` enumerates by.

  The bootstrap script is passed as the instance's `startup-script` metadata via
  a temporary file, since it is far too large for an inline `--metadata` value.

  `gcloud compute instances create` blocks until the instance reaches `RUNNING`,
  which takes roughly 20-40 seconds; callers should budget for a minute. Note
  that `{:ok, _}` means *the VM is running*, not that Hyper is up on it — the
  startup script still has to install the Firecracker host prerequisites and
  pull the release, which takes several more minutes. Covering that gap is the
  autoscaler's job, via its pending-with-deadline accounting.

  The `t:Hyper.Provider.cfg/0` map may use atom or string keys and carries:
  `:project`, `:zone`, `:machine_type`, `:image_family`, `:image_project`,
  `:boot_disk_gb`, `:hostname_prefix`, `:service_account`, `:scopes`,
  `:network_tags`.

  Failures are surfaced as `{:error, {:gcp, ...}}` tuples, with `gcloud`'s own
  (stderr-merged) output included on a non-zero exit so the operator can see
  what the API refused.
  """

  @behaviour Hyper.Provider

  require Logger

  @default_machine_type "n2-standard-4"
  @default_image_family "ubuntu-2404-lts-amd64"
  @default_image_project "ubuntu-os-cloud"
  @default_boot_disk_gb 50
  @default_hostname_prefix "hyper-worker"
  @default_scopes "https://www.googleapis.com/auth/cloud-platform"

  @worker_label "hyper-role=worker"

  @required_cfg_keys [:project, :zone]
  @required_bootstrap_keys [:release_url, :pg_url, :cookie]

  @max_instance_name_len 63

  @impl Hyper.Provider
  @spec cfg_namespace() :: String.t()
  def cfg_namespace, do: "gcp"

  @impl Hyper.Provider
  @spec template_segments() :: [String.t()]
  def template_segments, do: ["priv", "deploy", "gcp", "startup-script.sh.eex"]

  @impl Hyper.Provider
  @spec validate_cfg(Hyper.Provider.cfg()) :: :ok | {:error, term()}
  def validate_cfg(cfg) do
    bootstrap = bootstrap_cfg(cfg)

    missing =
      Enum.filter(@required_cfg_keys, &blank?(optional_cfg(cfg, &1))) ++
        Enum.filter(@required_bootstrap_keys, &blank?(optional_cfg(bootstrap, &1)))

    case missing do
      [] -> :ok
      keys -> {:error, {:gcp, :missing_cfg, keys}}
    end
  end

  @impl Hyper.Provider
  @spec create_node(Hyper.Provider.cfg(), String.t()) ::
          {:ok, Hyper.Provider.node_ref()} | {:error, term()}
  def create_node(cfg, user_data) do
    with {:ok, project} <- require_cfg(cfg, :project),
         {:ok, zone} <- require_cfg(cfg, :zone) do
      name = build_name(cfg)
      path = Path.join(System.tmp_dir!(), "hyper-startup-#{name}.sh")

      case File.write(path, user_data) do
        :ok ->
          try do
            run_create(cfg, project, zone, name, path)
          after
            _ = File.rm(path)
          end

        {:error, reason} ->
          {:error, {:gcp, :startup_script_write_failed, reason}}
      end
    end
  end

  @impl Hyper.Provider
  @spec destroy_node(Hyper.Provider.cfg(), String.t()) :: :ok | {:error, term()}
  def destroy_node(cfg, ref) do
    with {:ok, project} <- require_cfg(cfg, :project),
         {:ok, zone} <- require_cfg(cfg, :zone) do
      args = [
        "compute",
        "instances",
        "delete",
        ref,
        "--zone=#{zone}",
        "--project=#{project}",
        "--quiet"
      ]

      case gcloud(args) do
        {:ok, _output} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl Hyper.Provider
  @spec list_nodes(Hyper.Provider.cfg()) ::
          {:ok, [Hyper.Provider.node_ref()]} | {:error, term()}
  def list_nodes(cfg) do
    with {:ok, project} <- require_cfg(cfg, :project),
         {:ok, zone} <- require_cfg(cfg, :zone) do
      args = [
        "compute",
        "instances",
        "list",
        "--project=#{project}",
        "--zones=#{zone}",
        "--filter=labels.#{@worker_label}",
        "--format=json"
      ]

      with {:ok, output} <- gcloud(args),
           {:ok, items} <- decode_instances(output) do
        {:ok, Enum.map(items, &to_node_ref/1)}
      end
    end
  end

  @spec run_create(Hyper.Provider.cfg(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, Hyper.Provider.node_ref()} | {:error, term()}
  defp run_create(cfg, project, zone, name, script_path) do
    args =
      [
        "compute",
        "instances",
        "create",
        name,
        "--project=#{project}",
        "--zone=#{zone}",
        "--machine-type=#{cfg_or(cfg, :machine_type, @default_machine_type)}",
        "--image-family=#{cfg_or(cfg, :image_family, @default_image_family)}",
        "--image-project=#{cfg_or(cfg, :image_project, @default_image_project)}",
        "--boot-disk-size=#{cfg_or(cfg, :boot_disk_gb, @default_boot_disk_gb)}GB",
        "--enable-nested-virtualization",
        "--labels=#{@worker_label}",
        "--metadata-from-file=startup-script=#{script_path}",
        "--scopes=#{cfg_or(cfg, :scopes, @default_scopes)}",
        "--format=json"
      ] ++ optional_flags(cfg)

    with {:ok, output} <- gcloud(args),
         {:ok, [instance | _rest]} <- decode_instances(output) do
      {:ok, %{ref: name, hostname: name, ip: internal_ip(instance), status: "RUNNING"}}
    else
      {:ok, []} ->
        Logger.warning("gcp create_node: gcloud returned no instance for #{name}")
        {:error, {:gcp, :unexpected_create_response, name}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec optional_flags(Hyper.Provider.cfg()) :: [String.t()]
  defp optional_flags(cfg) do
    service_account =
      case optional_cfg(cfg, :service_account) do
        nil -> []
        account -> ["--service-account=#{account}"]
      end

    tags =
      case optional_cfg(cfg, :network_tags) do
        nil -> []
        tags when is_list(tags) -> ["--tags=#{Enum.join(tags, ",")}"]
        tags -> ["--tags=#{tags}"]
      end

    service_account ++ tags
  end

  @spec gcloud([String.t()]) :: {:ok, String.t()} | {:error, term()}
  defp gcloud(args) do
    case System.cmd("gcloud", args, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, output}

      {output, status} ->
        Logger.warning("gcloud #{Enum.join(args, " ")} exited #{status}: #{output}")
        {:error, {:gcp, :create_failed, status, output}}
    end
  end

  # `gcloud` is run with stderr merged into stdout so its errors survive into the
  # {:error, _} tuple. That also puts its progress chatter ("WARNING: ...",
  # "Created [...]") ahead of the JSON payload, which Jason rejects outright.
  # Decoding a *successful* create as a failure is the expensive direction of
  # wrong: the caller retries and leaks the instance that was already created.
  @spec json_payload(String.t()) :: String.t()
  defp json_payload(output) do
    case :binary.match(output, ["\n[", "\n{"]) do
      {at, _len} -> binary_part(output, at + 1, byte_size(output) - at - 1)
      :nomatch -> output
    end
  end

  @spec decode_instances(String.t()) :: {:ok, [map()]} | {:error, term()}
  defp decode_instances(output) do
    case output |> json_payload() |> Jason.decode() do
      {:ok, items} when is_list(items) ->
        {:ok, Enum.filter(items, &is_map/1)}

      {:ok, other} ->
        Logger.warning("gcp: expected a JSON array of instances, got: #{inspect(other)}")
        {:error, {:gcp, :unexpected_json, other}}

      {:error, reason} ->
        Logger.warning("gcp: gcloud output was not JSON: #{inspect(reason)}")
        {:error, {:gcp, :invalid_json, output}}
    end
  end

  @spec internal_ip(map()) :: String.t() | nil
  defp internal_ip(instance) do
    case Map.get(instance, "networkInterfaces") do
      [%{"networkIP" => ip} | _rest] when is_binary(ip) ->
        ip

      other ->
        Logger.warning("gcp: no internal IP in networkInterfaces: #{inspect(other)}")
        nil
    end
  end

  @spec to_node_ref(map()) :: Hyper.Provider.node_ref()
  defp to_node_ref(instance) do
    name = Map.get(instance, "name") || ""

    %{
      ref: name,
      hostname: name,
      ip: internal_ip(instance),
      status: Map.get(instance, "status") || "unknown"
    }
  end

  @spec build_name(Hyper.Provider.cfg()) :: String.t()
  defp build_name(cfg) do
    suffix = "-#{System.unique_integer([:positive, :monotonic])}"

    prefix =
      cfg
      |> cfg_or(:hostname_prefix, @default_hostname_prefix)
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9-]/, "-")
      |> String.trim_leading("-")
      |> String.slice(0, @max_instance_name_len - String.length(suffix))

    case prefix do
      "" -> @default_hostname_prefix <> suffix
      p -> p <> suffix
    end
  end

  @spec bootstrap_cfg(Hyper.Provider.cfg()) :: map()
  defp bootstrap_cfg(cfg) do
    case optional_cfg(cfg, :bootstrap) do
      bootstrap when is_map(bootstrap) -> bootstrap
      _other -> cfg
    end
  end

  @spec cfg_or(Hyper.Provider.cfg(), atom(), term()) :: term()
  defp cfg_or(cfg, key, default) do
    case optional_cfg(cfg, key) do
      nil -> default
      value -> value
    end
  end

  @spec require_cfg(Hyper.Provider.cfg(), atom()) :: {:ok, term()} | {:error, term()}
  defp require_cfg(cfg, key) do
    case optional_cfg(cfg, key) do
      nil -> {:error, {:gcp, :missing_cfg, [key]}}
      value -> {:ok, value}
    end
  end

  @spec optional_cfg(map(), atom()) :: term() | nil
  defp optional_cfg(cfg, key) when is_map(cfg) do
    Map.get(cfg, key, Map.get(cfg, Atom.to_string(key)))
  end

  @spec blank?(term()) :: boolean()
  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false
end
