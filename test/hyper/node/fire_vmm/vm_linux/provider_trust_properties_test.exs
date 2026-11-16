defmodule Hyper.Node.FireVMM.VmLinux.ProviderTrustPropertiesTest do
  @moduledoc """
  Kernel trust in `Hyper.Node.FireVMM.VmLinux.Provider`: a cached kernel is
  only booted when no jail could have rewritten it.

  Laws:

    * `usable?/2` oracle: for every permission mode (setuid/setgid/sticky
      included) and every expected owner, a regular file is usable exactly when
      it carries no group- or other-write bit and is owned by root or that
      owner; with no known owner (`nil`) only root qualifies;
    * a non-regular path (directory, FIFO, dangling or live symlink) is never
      usable, and judging it never blocks;
    * `install_state/3` oracle: with each build independently faithful, stale,
      missing, loosened, or replaced by a symlink to a faithful copy, the state
      is `:ok` iff every build is faithful, `:not_installed` iff none is, and
      `:bad_install` otherwise.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Hyper.Node.FireVMM.VmLinux.{Manifest, Provider}

  setup do
    dir = Path.join(System.tmp_dir!(), "vmlinux-trust-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir, me: File.stat!(dir).uid}
  end

  property "usable?/2 holds exactly for root- or owner-owned files no group or other can write",
           %{dir: dir, me: me} do
    path = Path.join(dir, "vmlinux")
    File.write!(path, "kernel")

    check all(
            mode <- integer(0..0o7777),
            owner <- member_of([me, me + 1, 0, nil]),
            max_runs: 400
          ) do
      File.chmod!(path, mode)
      %File.Stat{mode: actual, uid: uid} = File.stat!(path)

      expected =
        Bitwise.band(actual, 0o022) == 0 and (uid == 0 or uid == owner)

      assert Provider.usable?(path, owner) == expected,
             "mode #{Integer.to_string(actual, 8)}, owner #{inspect(owner)}"
    end
  end

  test "a non-regular path is never usable and judging it never blocks", %{dir: dir, me: me} do
    trusted = Path.join(dir, "trusted")
    File.write!(trusted, "kernel")
    File.chmod!(trusted, 0o644)

    fifo = Path.join(dir, "fifo")
    {_, 0} = System.cmd("mkfifo", ["-m", "0644", fifo])

    subdir = Path.join(dir, "subdir")
    File.mkdir_p!(subdir)
    File.chmod!(subdir, 0o755)

    live = Path.join(dir, "live-link")
    File.ln_s!(trusted, live)
    dangling = Path.join(dir, "dangling-link")
    File.ln_s!(Path.join(dir, "nowhere"), dangling)

    verdicts =
      for {name, path} <- [fifo: fifo, directory: subdir, live_link: live, dangling: dangling] do
        task = Task.async(fn -> Provider.usable?(path, me) end)
        {name, Task.yield(task, 2_000) || Task.shutdown(task, :brutal_kill)}
      end

    assert verdicts == [
             fifo: {:ok, false},
             directory: {:ok, false},
             live_link: {:ok, false},
             dangling: {:ok, false}
           ]
  end

  defp build_condition, do: member_of([:faithful, :stale, :missing, :loose, :symlinked])

  property "install_state/3 is :ok iff every build is faithful and :not_installed iff none is",
           %{dir: dir, me: me} do
    builds = Manifest.builds_for(:x86_64)
    assert length(builds) > 1

    check all(conditions <- list_of(build_condition(), length: length(builds)), max_runs: 100) do
      case_dir = Path.join(dir, "case-#{System.unique_integer([:positive])}")
      File.mkdir_p!(case_dir)
      staged = Enum.zip_with(builds, conditions, &stage(case_dir, &1, &2))
      faithful = Enum.count(conditions, &(&1 == :faithful))

      expected =
        cond do
          faithful == length(builds) -> :ok
          faithful == 0 -> {:error, :not_installed}
          true -> {:error, :bad_install}
        end

      assert Provider.install_state(case_dir, staged, me) == expected, inspect(conditions)
    end
  end

  defp stage(dir, build, condition) do
    content = "kernel #{build.asset}"
    sha = Base.encode16(:crypto.hash(:sha256, content), case: :lower)
    path = Path.join(dir, build.asset)

    case condition do
      :faithful ->
        write(path, content, 0o644)

      :stale ->
        write(path, "previous release #{build.asset}", 0o644)

      :missing ->
        :ok

      :loose ->
        write(path, content, 0o664)

      :symlinked ->
        real = Path.join(dir, "real-#{build.asset}")
        write(real, content, 0o644)
        File.ln_s!(real, path)
    end

    %{build | sha256: sha}
  end

  defp write(path, content, mode) do
    File.write!(path, content)
    File.chmod!(path, mode)
  end
end
