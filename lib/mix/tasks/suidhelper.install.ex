defmodule Mix.Tasks.Suidhelper.Install do
  @shortdoc "Build, stamp, and install the setuid helper"
  @moduledoc """
  Builds, stamps, and installs the Rust setuid helper.

      mix suidhelper.install

  Two steps:

    1. `cargo xtask stamp` in `native/suidhelper` builds the release binary and
       writes its BLAKE3 self-checksum into `.note.sum` (the same step the
       `:suidhelper_stamp` compiler runs).
    2. The stamped binary is copied setuid-root (mode `4755`) to
       `/usr/local/bin/hyper-suidhelper`.

  The copy needs root, but Mix runs every subprocess in its own session with no
  controlling terminal (`erl_child_setup` calls `setsid`), so a nested `sudo`
  cannot open `/dev/tty` to prompt for a password. This task therefore only runs
  `sudo` itself when it is already non-interactive (`sudo -n` succeeds, e.g.
  `NOPASSWD` or a usable cached credential). Otherwise it prints the exact
  privileged command for you to run in your own terminal.

  This is the privileged counterpart to `mix suidhelper.stamp`, which stamps
  only. `cargo` and the helper's toolchain (see
  `native/suidhelper/rust-toolchain.toml`) must be installed.
  """

  use Mix.Task

  @helper_dir "native/suidhelper"
  @source Path.join(@helper_dir, "target/release/hyper-suidhelper")
  # Must match `Hyper.Config`'s default `suid_helper` path and the xtask's
  # `INSTALL_PATH`: a `PATH` location the unprivileged node can exec.
  @install_path "/usr/local/bin/hyper-suidhelper"

  @impl Mix.Task
  def run(argv) do
    stamp!(argv)
    install_privileged()
  end

  defp stamp!(argv) do
    case System.cmd("cargo", ["xtask", "stamp" | argv],
           cd: @helper_dir,
           into: IO.stream(:stdio, :line)
         ) do
      {_, 0} ->
        :ok

      {_, _} ->
        Mix.raise("""
        `cargo xtask stamp` failed building the suidhelper.

        Ensure `cargo` and the helper's toolchain (see #{@helper_dir}/rust-toolchain.toml)
        are installed.
        """)
    end
  end

  defp install_privileged do
    if passwordless_sudo?() do
      Mix.shell().info("Installing #{@source} -> #{@install_path} (setuid root)")

      case System.cmd("sudo", install_argv(), into: IO.stream(:stdio, :line)) do
        {_, 0} -> Mix.shell().info("installed #{@install_path} (setuid root)")
        {_, _} -> Mix.raise(manual_instructions())
      end
    else
      Mix.shell().info(manual_instructions())
    end
  end

  # `sudo -n true` exits 0 only when sudo can run without prompting. With no
  # controlling terminal a cached `tty_tickets` credential is invisible, so this
  # is true essentially only under `NOPASSWD` -- exactly the case where the
  # nested `sudo install` below can succeed.
  defp passwordless_sudo? do
    match?({_, 0}, System.cmd("sudo", ["-n", "true"], stderr_to_stdout: true))
  end

  defp install_argv,
    do: ["install", "-o", "root", "-g", "root", "-m", "4755", @source, @install_path]

  defp manual_instructions do
    """

    The binary is built and stamped, but installing it setuid-root needs a
    password and `sudo` has no terminal to prompt on here. Run the copy yourself:

        sudo #{Enum.join(install_argv(), " ")}
    """
  end
end
