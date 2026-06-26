defmodule Mix.Tasks.Firecracker.Install do
  @shortdoc "Download, verify, and install the pinned Firecracker release"
  @moduledoc """
  Downloads, verifies, and installs the pinned Firecracker release (v1.16.0)
  for the current CPU architecture.

      mix firecracker.install [--prefix DIR]

  Steps performed:

    1. Detects the CPU architecture (`x86_64` or `aarch64`).
    2. Downloads the release tarball and verifies its SHA-256 checksum.
    3. Extracts the tarball, then copies the binaries to `<prefix>/firecracker`
       and `<prefix>/jailer` using the **bare basenames** `firecracker` and
       `jailer`. The setuid helper validates binaries via `SafeBin<"firecracker">`
       and `SafeBin<"jailer">`, which match on basename only — version-stamped
       names such as `firecracker-v1.16.0-x86_64` are rejected unconditionally.
    4. Marks both binaries executable (`0o755`).
    5. Prints the `/etc/hyper/config.toml` snippet the operator needs to paste.

  This task installs **unprivileged** binaries and prints configuration.
  Privilege at runtime is handled by `hyper-suidhelper` (the setuid helper).
  This task does **not** setuid `firecracker` or `jailer`. Install and setuid
  the helper separately with `mix suidhelper.install`.

  ## Options

    * `--prefix DIR` — installation directory (default: `/opt/firecracker`).

  ## Security requirements

  After installing, ensure:

    * The binaries are root-owned and **not** group- or world-writable.
      The suidhelper refuses binaries with loose permissions.
    * `/etc/hyper/config.toml` is root-owned with mode `0644`.
  """

  use Mix.Task

  @version "1.16.0"
  @default_prefix "/opt/firecracker"

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: [prefix: :string])
    prefix = Keyword.get(opts, :prefix, @default_prefix)

    arch = detect_arch!()

    case Application.ensure_all_started(:req) do
      {:ok, _} -> :ok
      {:error, {reason, app}} -> Mix.raise("Cannot start HTTP client #{app}: #{inspect(reason)}")
    end

    install!(release_for(arch), prefix)
    print_config(prefix)
  end

  defp detect_arch! do
    case Sys.Arch.current() do
      {:ok, arch} ->
        arch

      {:error, {:unsupported_arch, raw}} ->
        Mix.raise(
          "Unsupported CPU architecture #{inspect(raw)}; " <>
            "Firecracker supports x86_64 and aarch64."
        )
    end
  end

  defp release_for(:x86_64) do
    %{
      url:
        "https://github.com/firecracker-microvm/firecracker/releases/download/" <>
          "v#{@version}/firecracker-v#{@version}-x86_64.tgz",
      sha256: "bd04e26952d4e158085778c6230a0b383d2619c319182e27eaa9d61a212e92d6",
      firecracker_path: "release-v#{@version}-x86_64/firecracker-v#{@version}-x86_64",
      jailer_path: "release-v#{@version}-x86_64/jailer-v#{@version}-x86_64"
    }
  end

  defp release_for(:aarch64) do
    %{
      url:
        "https://github.com/firecracker-microvm/firecracker/releases/download/" <>
          "v#{@version}/firecracker-v#{@version}-aarch64.tgz",
      sha256: "531c713cdbc37d4b8bc2533d851aabc0267096afa1768086a37672abb668efd7",
      firecracker_path: "release-v#{@version}-aarch64/firecracker-v#{@version}-aarch64",
      jailer_path: "release-v#{@version}-aarch64/jailer-v#{@version}-aarch64"
    }
  end

  defp install!(
         %{url: url, sha256: sha256, firecracker_path: fc_rel, jailer_path: jailer_rel},
         prefix
       ) do
    extract_dir = Path.join(prefix, ".firecracker-extract")

    Mix.shell().info("Downloading Firecracker v#{@version} from #{url} ...")

    case Redist.Targz.install(url, sha256, extract_dir) do
      :ok -> :ok
      {:error, reason} -> Mix.raise("Download from #{url} failed: #{inspect(reason)}")
    end

    dst_fc = Path.join(prefix, "firecracker")
    dst_jailer = Path.join(prefix, "jailer")

    # The release ships version-stamped names; copy to bare basenames so SafeBin
    # validation passes. The helper matches on basename, not full path.
    File.cp!(Path.join(extract_dir, fc_rel), dst_fc)
    File.cp!(Path.join(extract_dir, jailer_rel), dst_jailer)
    File.chmod!(dst_fc, 0o755)
    File.chmod!(dst_jailer, 0o755)
    _ = File.rm_rf!(extract_dir)

    Mix.shell().info("Installed #{dst_fc}")
    Mix.shell().info("Installed #{dst_jailer}")
  end

  defp print_config(prefix) do
    fc = Path.join(prefix, "firecracker")
    jailer = Path.join(prefix, "jailer")

    # This task runs unprivileged, so the binaries land owned by the invoking
    # user. The suidhelper's SafeBin refuses any binary not owned by root and not
    # free of group/other write bits, so the operator MUST chown/chmod them or
    # every jailer launch fails closed. Print the exact commands rather than a
    # vague "ensure root-owned".
    Mix.shell().info("""

    Almost done. Run these as root so the setuid helper will accept the binaries
    (it refuses any jailer/firecracker not owned by root):

        sudo chown root:root #{fc} #{jailer}
        sudo chmod 0755      #{fc} #{jailer}

    Then add to /etc/hyper/config.toml (file: root-owned, mode 0644):

        [tools]
        firecracker = "#{fc}"
        jailer      = "#{jailer}"
    """)
  end
end
