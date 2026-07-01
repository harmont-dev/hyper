defmodule Mix.Tasks.GuestAgent.Install do
  @shortdoc "Build and install the static guest-agent binaries for both architectures"
  @moduledoc """
  Builds the `hyper-guest-agent` static musl binary for both supported
  architectures and installs each to the path resolved by
  `Hyper.Node.FireVMM.GuestAgent.path/1`.

      mix guest_agent.install

  Two steps per architecture:

    1. `cargo build --release --target <musl-triple>` in `native/guest-agent`
       produces a fully static binary (no glibc dependency) suitable for running
       as guest PID 1 inside a stripped-down Firecracker rootfs.
    2. The binary is copied to `Hyper.Cfg.Dirs.guest_agent_install_dir/0`
       (`<work_dir>/redist/guest-agent/hyper-guest-agent-<arch>`).

  The install directory is created if it does not exist. No elevated privileges
  are required — unlike the suidhelper, the guest-agent binary is not setuid.
  `cargo` and the musl cross-compilation toolchains must be installed:

    - `x86_64-unknown-linux-musl` (via `rustup target add`)
    - `aarch64-unknown-linux-musl` (via `rustup target add`)
  """

  use Mix.Task

  alias Hyper.Node.FireVMM.GuestAgent

  @agent_dir "native/guest-agent"

  @arches [
    x86_64: "x86_64-unknown-linux-musl",
    aarch64: "aarch64-unknown-linux-musl"
  ]

  @impl Mix.Task
  def run(_argv) do
    for {arch, triple} <- @arches do
      build!(arch, triple)
      install!(arch, triple)
    end

    :ok
  end

  defp build!(arch, triple) do
    Mix.shell().info("Building guest-agent for #{arch} (#{triple})")

    case System.cmd(
           "cargo",
           ["build", "--release", "--target", triple],
           cd: @agent_dir,
           into: IO.stream(:stdio, :line)
         ) do
      {_, 0} ->
        :ok

      {_, _} ->
        Mix.raise("""
        `cargo build --release --target #{triple}` failed.

        Ensure `cargo` and the musl target are installed:

            rustup target add #{triple}
        """)
    end
  end

  defp install!(arch, triple) do
    source = Path.join(@agent_dir, "target/#{triple}/release/hyper-guest-agent")
    dest = GuestAgent.path(arch)

    File.mkdir_p!(Path.dirname(dest))
    File.cp!(source, dest)
    Mix.shell().info("Installed #{dest}")
  end
end
