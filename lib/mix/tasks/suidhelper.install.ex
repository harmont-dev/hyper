defmodule Mix.Tasks.Suidhelper.Install do
  @shortdoc "Build, stamp, and install the setuid helper"
  @moduledoc """
  Builds, stamps, and installs the Rust setuid helper.

      mix suidhelper.install --group GROUP

  Two steps:

    1. `cargo xtask stamp` in `native/suidhelper` builds the release binary and
       writes its BLAKE3 self-checksum into `.note.sum` (the same step the
       `:suidhelper_stamp` compiler runs).
    2. The stamped binary is copied setuid-root to
       `/usr/local/libexec/hyper/hyper-suidhelper`, owned `root:GROUP`, mode
       `4750`, inside a `root:GROUP` `0750` directory: only root and GROUP may
       run it, and the helper refuses anyone else. GROUP is required, must
       include you, and must contain no other account.

  The copy needs root, but Mix runs every subprocess in its own session with no
  controlling terminal (`erl_child_setup` calls `setsid`), so a nested `sudo`
  cannot open `/dev/tty` to prompt for a password. This task therefore only runs
  `sudo` itself when it is already non-interactive (`sudo -n` succeeds, e.g.
  `NOPASSWD` or a usable cached credential). Otherwise it prints the exact
  privileged command for you to run in your own terminal.

  This is the privileged counterpart to `mix suidhelper.stamp`, which stamps
  only. `cargo` and the helper's toolchain (see
  `native/rust-toolchain.toml`) must be installed.
  """

  use Mix.Task

  # Anchored to this file (not the cwd) so the task also works when hyper is a
  # dependency: there the crate lives under deps/hypervm/native/suidhelper, not
  # under the consumer project's root.
  @helper_dir Path.expand("../../../native/suidhelper", __DIR__)
  # Must match `Hyper.Cfg.Tools.suidhelper/0`'s default path.
  @install_dir "/usr/local/libexec/hyper"
  @install_path "/usr/local/libexec/hyper/hyper-suidhelper"
  @legacy_path "/usr/local/bin/hyper-suidhelper"

  @impl Mix.Task
  def run(argv) do
    {group, argv} = group_option(argv)
    group = node_group!(group)
    argv |> stamp!() |> install_privileged(group)
  end

  defp group_option(argv) do
    case Enum.split_while(argv, &(&1 != "--group")) do
      {before, ["--group", group | rest]} ->
        {group, before ++ rest}

      _ ->
        Mix.raise("""
        Pass the node's dedicated group: mix suidhelper.install --group GROUP

        The setuid helper runs privileged operations only for root and members of
        GROUP, so GROUP must contain the node's account and no other.
        """)
    end
  end

  # The helper trusts every member of its group, so the group must hold the
  # node's account alone: listed members and accounts with it as their primary
  # group both count.
  defp node_group!(group) do
    me = id!(["-un"])

    unless group in String.split(id!(["-Gn"])) do
      Mix.raise("#{me} is not in group #{group}; the node must run in the helper's group")
    end

    [_name, _password, gid, members] = String.split(getent!(["group", group]), ":")
    others = Enum.uniq(String.split(members, ",", trim: true) ++ primary_members(gid)) -- [me]

    if others != [] do
      Mix.raise("""
      Group #{group} also contains #{Enum.join(others, ", ")}. The setuid helper trusts
      every member of its group, so it needs one only the node's account is in:

          sudo groupadd --system hyper && sudo usermod -aG hyper #{me}

      then log in again and run `mix suidhelper.install --group hyper`.
      """)
    end

    group
  end

  defp primary_members(gid) do
    for line <- String.split(getent!(["passwd"]), "\n", trim: true),
        [name, _password, _uid, ^gid | _] <- [String.split(line, ":")],
        do: name
  end

  defp id!(args), do: run!("id", args)
  defp getent!(args), do: run!("getent", args)

  defp run!(cmd, args) do
    case System.cmd(cmd, args) do
      {out, 0} -> String.trim(out)
      {_, status} -> Mix.raise("`#{cmd} #{Enum.join(args, " ")}` failed (exit #{status})")
    end
  end

  defp stamp!(argv) do
    case System.cmd("cargo", ["xtask", "stamp" | argv], cd: @helper_dir) do
      {output, 0} ->
        String.trim(output)

      {_, _} ->
        Mix.raise("""
        `cargo xtask stamp` failed building the suidhelper.

        Ensure `cargo`, the helper's toolchain and its musl target (see #{@helper_dir}/rust-toolchain.toml)
        are installed.
        """)
    end
  end

  defp install_privileged(source, group) do
    if passwordless_sudo?() do
      Mix.shell().info("Installing #{source} -> #{@install_path} (setuid root, group #{group})")

      Enum.each(install_commands(source, group), fn argv ->
        case System.cmd("sudo", argv, into: IO.stream(:stdio, :line)) do
          {_, 0} -> :ok
          {_, _} -> Mix.raise(manual_instructions(source, group))
        end
      end)

      Mix.shell().info("installed #{@install_path} (setuid root, group #{group})")
    else
      Mix.shell().info(manual_instructions(source, group))
    end
  end

  # `sudo -n true` exits 0 only when sudo can run without prompting. With no
  # controlling terminal a cached `tty_tickets` credential is invisible, so this
  # is true essentially only under `NOPASSWD` -- exactly the case where the
  # nested `sudo install` below can succeed.
  defp passwordless_sudo? do
    match?({_, 0}, System.cmd("sudo", ["-n", "true"], stderr_to_stdout: true))
  end

  defp install_commands(source, group) do
    [
      ["install", "-d", "-o", "root", "-g", group, "-m", "0750", @install_dir],
      ["install", "-o", "root", "-g", group, "-m", "4750", source, @install_path],
      ["rm", "-f", @legacy_path]
    ]
  end

  defp manual_instructions(source, group) do
    commands =
      Enum.map_join(install_commands(source, group), "\n", &"    sudo #{Enum.join(&1, " ")}")

    """

    The binary is built and stamped, but installing it setuid-root needs a
    password and `sudo` has no terminal to prompt on here. Run these yourself:

    #{commands}
    """
  end
end
