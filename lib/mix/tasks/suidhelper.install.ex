defmodule Mix.Tasks.Suidhelper.Install do
  @shortdoc "Build, stamp, and install the setuid helper (wraps `cargo xtask install`)"
  @moduledoc """
  Builds, stamps, and installs the Rust setuid helper by wrapping
  `cargo xtask install` in `native/suidhelper`.

      mix suidhelper.install

  The xtask first stamps the release binary (BLAKE3 self-checksum into
  `.note.sum`, the same step the `:suidhelper_stamp` compiler runs) and then
  installs it setuid-root to `/usr/local/bin/hyper-suidhelper` via `sudo
  install`. `sudo` may prompt for a password on the controlling terminal.

  This is the privileged counterpart to `mix suidhelper.stamp`: that one only
  rebuilds, stamps, and re-captures the embedded build identity; this one also
  places the binary on `PATH` setuid-root. `cargo` and the helper's toolchain
  (see `native/suidhelper/rust-toolchain.toml`) must be installed.
  """

  use Mix.Task

  @helper_dir "native/suidhelper"

  @impl Mix.Task
  def run(argv) do
    {_, 0} =
      System.cmd("cargo", ["xtask", "install" | argv],
        cd: @helper_dir,
        into: IO.stream(:stdio, :line)
      )
  rescue
    MatchError ->
      Mix.raise("""
      `cargo xtask install` failed installing the suidhelper.

      Ensure `cargo` and the helper's toolchain (see #{@helper_dir}/rust-toolchain.toml)
      are installed, and that `sudo` is available for the setuid install step.
      """)
  end
end
