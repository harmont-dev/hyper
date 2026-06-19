# Firecracker VMM Provider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hard-coded `jailer_bin`, `firecracker_bin`, `jailer_chroot_base`, `socket_dir`, and `scratch_dir` config keys with a single `:work_dir`, and add a `Hyper.Node.FireVMM.Provider` module that downloads, SHA-256-verifies, and installs the firecracker + jailer binaries for the host architecture into `<work_dir>/redist/firecracker`.

**Architecture:** `Hyper.Config` keeps the same accessor names (`firecracker_bin/0`, `jailer_bin/0`, `chroot_base/0`, `socket_dir/0`, `scratch_dir/0`) but derives every path from a single compile-time `:work_dir`, so no downstream module changes. A new `Provider` module is the only thing that touches the network: on node boot it is idempotent (skips if the pinned version is already installed), otherwise it downloads the official firecracker release tarball for the detected architecture into a **temporary directory**, verifies its SHA-256 against a **pinned** per-arch digest, extracts it, copies `firecracker` and `jailer` into the install dir, and **always** removes the temp directory (`try/after`). The checksum is verified **before** extraction; a mismatch aborts without installing anything.

**Tech Stack:** Elixir `~> 1.19`, `Req` (HTTP, new dependency), `:erl_tar` + `:crypto` (stdlib), `:erlang.system_info/1` for arch detection.

## Global Constraints

- Elixir `~> 1.19` — copy idioms from existing modules; no new language features required.
- Firecracker version is pinned to `1.16.0` (module attribute `@version "1.16.0"` in `Provider`).
- Supported architectures: `"x86_64"` and `"aarch64"` only; anything else returns `{:error, {:unsupported_arch, raw_string}}`.
- Pinned SHA-256 digests (lowercase hex, contents of the release `*.sha256.txt` files):
  - `x86_64`: `bd04e26952d4e158085778c6230a0b383d2619c319182e27eaa9d61a212e92d6`
  - `aarch64`: `531c713cdbc37d4b8bc2533d851aabc0267096afa1768086a37672abb668efd7`
- Tarball URL: `https://github.com/firecracker-microvm/firecracker/releases/download/v<ver>/firecracker-v<ver>-<arch>.tgz`
- The tarball extracts to a single directory `release-v<ver>-<arch>/` containing the versioned binaries `firecracker-v<ver>-<arch>` and `jailer-v<ver>-<arch>`.
- Derived path layout, all under `:work_dir`:
  - `<work_dir>/redist/firecracker/firecracker` → `firecracker_bin/0`
  - `<work_dir>/redist/firecracker/jailer` → `jailer_bin/0`
  - `<work_dir>/redist/firecracker/.fc-version` → install marker (contents = `@version`, no trailing newline)
  - `<work_dir>/jails` → `chroot_base/0`
  - `<work_dir>/socks` → `socket_dir/0`
  - `<work_dir>/scratch` → `scratch_dir/0`
- The temp directory used for download/extraction MUST always be removed, even on failure (`try/after` with `File.rm_rf!/1`).
- No new runtime config knobs for binary paths — everything is derived from `:work_dir`.

## File Structure

- **Create** `lib/hyper/node/fire_vmm/provider.ex` — the only module that downloads/installs firecracker. Pure-ish functions (`target_arch/0`, `sha256_file/1`, `verify_checksum/2`, `extract_and_install/3`, `installed?/1`) plus the `ensure_installed/1` orchestrator with dependency-injectable `:fetch`/`:checksums`/`:arch`/`:install_dir` opts for hermetic tests.
- **Create** `test/hyper/node/fire_vmm/provider_test.exs` — unit tests; no network (builds fixture tarballs with `:erl_tar`, injects a fake `:fetch`).
- **Create** `test/hyper/config_test.exs` — asserts the derived paths.
- **Modify** `mix.exs` — add `{:req, "~> 0.5"}`.
- **Modify** `lib/hyper/config.ex` — replace the 5 removed attributes/accessors with `:work_dir` + derived paths.
- **Modify** `config/config.exs` — replace the 5 removed keys with `work_dir:`; add a test-env `work_dir` + provider settings.
- **Modify** `lib/hyper/node.ex` — call `Provider.ensure_installed/0` first in `test_system/0`.
- **Modify** `lib/hyper/node/fire_vmm/jailer.ex` — moduledoc only (config keys changed).
- **Create** `test/support/firecracker_work_dir/redist/firecracker/{firecracker,jailer,.fc-version}` — committed offline fixtures so `mix test` boots the node without network.
- **Modify** `.gitignore` — ignore the runtime subdirs created under the test work dir.

---

### Task 1: Add the `Req` HTTP dependency

**Files:**
- Modify: `mix.exs:38-55` (the `deps/0` list)

**Interfaces:**
- Consumes: nothing.
- Produces: `Req` available at runtime (used by `Provider.default_fetch/2` in Task 7).

- [ ] **Step 1: Add `:req` to deps**

In `mix.exs`, inside `defp deps do [ ... ] end`, add the `:req` line (keep the list alphabetical-ish, matching the existing style):

```elixir
    {:postgrex, "~> 0.20"},
    {:req, "~> 0.5"},
    {:uuidv4, "~> 1.0"}
```

- [ ] **Step 2: Fetch and compile**

Run: `mix deps.get && mix compile`
Expected: `req` (and its transitive deps `finch`, `mint`, `nimble_options`, `castore`, …) are fetched; compile succeeds with no errors.

- [ ] **Step 3: Verify Req is loadable**

Run: `mix run -e 'true = Code.ensure_loaded?(Req); IO.puts("req ok")'`
Expected: prints `req ok`.

- [ ] **Step 4: Commit**

```bash
git add mix.exs mix.lock
git commit -m "build: add req http client dependency"
```

---

### Task 2: Refactor `Hyper.Config` to a single `:work_dir`

**Files:**
- Modify: `lib/hyper/config.ex:4-14` (attributes) and `:19-45,87-92` (accessors)
- Modify: `config/config.exs:30-38`
- Test: `test/hyper/config_test.exs` (create)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `Hyper.Config.work_dir() :: Path.t()`
  - `Hyper.Config.redist_dir() :: Path.t()` → `<work_dir>/redist`
  - `Hyper.Config.firecracker_install_dir() :: Path.t()` → `<work_dir>/redist/firecracker`
  - `Hyper.Config.firecracker_bin() :: Path.t()` → `<install_dir>/firecracker`
  - `Hyper.Config.jailer_bin() :: Path.t()` → `<install_dir>/jailer`
  - `Hyper.Config.chroot_base() :: Path.t()` → `<work_dir>/jails`
  - `Hyper.Config.socket_dir() :: Path.t()` → `<work_dir>/socks`
  - `Hyper.Config.scratch_dir() :: Path.t()` → `<work_dir>/scratch`
  - (unchanged: `parent_cgroup/0`, `uid_gid_range/0`, `layer_dir/0`, `losetup_path/0`, `dmsetup_path/0`, `blockdev_path/0`, `suid_helper/0`, `chunk_sectors/0`)

- [ ] **Step 1: Write the failing test**

Create `test/hyper/config_test.exs`:

```elixir
defmodule Hyper.ConfigTest do
  use ExUnit.Case, async: true

  alias Hyper.Config

  test "all firecracker paths are derived from work_dir" do
    wd = Config.work_dir()

    assert Config.redist_dir() == Path.join(wd, "redist")
    assert Config.firecracker_install_dir() == Path.join([wd, "redist", "firecracker"])
    assert Config.firecracker_bin() == Path.join([wd, "redist", "firecracker", "firecracker"])
    assert Config.jailer_bin() == Path.join([wd, "redist", "firecracker", "jailer"])
    assert Config.chroot_base() == Path.join(wd, "jails")
    assert Config.socket_dir() == Path.join(wd, "socks")
    assert Config.scratch_dir() == Path.join(wd, "scratch")
  end

  test "the firecracker binary basename is stable" do
    assert Path.basename(Config.firecracker_bin()) == "firecracker"
    assert Path.basename(Config.jailer_bin()) == "jailer"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/hyper/config_test.exs`
Expected: FAIL — `work_dir/0`, `redist_dir/0`, `firecracker_install_dir/0` are undefined (and compile fails because `config.exs` still requires removed keys).

- [ ] **Step 3: Update `config/config.exs`**

Replace the `config :hyper, ...` block at `config/config.exs:30-38` with (note: removed `jailer_bin`, `firecracker_bin`, `jailer_chroot_base`, `socket_dir`, `scratch_dir`; added `work_dir`):

```elixir
config :hyper,
  work_dir: "/srv/hyper",
  cgroup_parent: "hyper",
  uid_gid_range: {900_000, 999_999},
  layer_dir: "/srv/hyper/layers"
```

Then, inside the existing `if config_env() == :test do ... end` block at `config/config.exs:24-28`, add (so tests use a repo-local work dir seeded with offline fixtures — see Task 9):

```elixir
  config :hyper, work_dir: Path.expand("../test/support/firecracker_work_dir", __DIR__)
```

- [ ] **Step 4: Rewrite the attributes in `lib/hyper/config.ex`**

Replace `lib/hyper/config.ex:4-14` (the attribute block — delete the `@jailer_bin`, `@firecracker_bin`, `@chroot_base`, `@socket_dir`, `@scratch_dir` lines) so the attributes read:

```elixir
  @work_dir Application.compile_env!(:hyper, :work_dir)
  @parent_cgroup Application.compile_env(:hyper, :cgroup_parent, "hyper")
  @uid_gid_range Application.compile_env!(:hyper, :uid_gid_range)
  @layer_dir Application.compile_env!(:hyper, :layer_dir)
  @losetup_path Application.compile_env(:hyper, :losetup_path, "losetup")
  @dmsetup_path Application.compile_env(:hyper, :dmsetup_path, "dmsetup")
  @blockdev_path Application.compile_env(:hyper, :blockdev_path, "blockdev")
```

(Leave the `@chunk_sectors` block at `:15-17` exactly as-is.)

- [ ] **Step 5: Rewrite the accessors in `lib/hyper/config.ex`**

Replace the `jailer_bin/0`, `firecracker_bin/0`, and `chroot_base/0` accessors (`lib/hyper/config.ex:19-31`) with the derived versions, and add `work_dir/0`, `redist_dir/0`, `firecracker_install_dir/0`:

```elixir
  @doc "Root work directory for this node. All firecracker paths derive from it."
  @spec work_dir :: Path.t()
  def work_dir, do: @work_dir

  @doc "Directory holding redistributable binaries downloaded by the node."
  @spec redist_dir :: Path.t()
  def redist_dir, do: Path.join(@work_dir, "redist")

  @doc "Directory where `Hyper.Node.FireVMM.Provider` installs firecracker + jailer."
  @spec firecracker_install_dir :: Path.t()
  def firecracker_install_dir, do: Path.join(redist_dir(), "firecracker")

  @doc "jailer binary path, installed by the provider. Identical across nodes."
  @spec jailer_bin :: Path.t()
  def jailer_bin, do: Path.join(firecracker_install_dir(), "jailer")

  @doc "firecracker binary path, installed by the provider. Identical across nodes."
  @spec firecracker_bin :: Path.t()
  def firecracker_bin, do: Path.join(firecracker_install_dir(), "firecracker")

  @doc """
  Path to the directory where all VM chroot's are created (`<work_dir>/jails`).

  If it does not exist, `Hyper.Node` will attempt to create one.
  """
  @spec chroot_base :: Path.t()
  def chroot_base, do: Path.join(@work_dir, "jails")
```

Then replace the `socket_dir/0` accessor (`lib/hyper/config.ex:44-45`) body and the `scratch_dir/0` accessor (`lib/hyper/config.ex:91-92`) body so they derive from `@work_dir`:

```elixir
  @spec socket_dir :: Path.t()
  def socket_dir, do: Path.join(@work_dir, "socks")
```

```elixir
  @spec scratch_dir :: Path.t()
  def scratch_dir, do: Path.join(@work_dir, "scratch")
```

- [ ] **Step 6: Run the config test**

Run: `mix test test/hyper/config_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 7: Confirm the rest still compiles**

Run: `mix compile --warnings-as-errors`
Expected: success. (`jailer.ex` is untouched — it still calls `Config.firecracker_bin/0`, `Config.jailer_bin/0`, `Config.chroot_base/0`, which now derive from `work_dir`.)

- [ ] **Step 8: Commit**

```bash
git add lib/hyper/config.ex config/config.exs test/hyper/config_test.exs
git commit -m "refactor: derive firecracker paths from a single :work_dir"
```

---

### Task 3: `Provider.target_arch/0` — architecture detection

**Files:**
- Create: `lib/hyper/node/fire_vmm/provider.ex`
- Test: `test/hyper/node/fire_vmm/provider_test.exs` (create)

**Interfaces:**
- Consumes: nothing.
- Produces: `Hyper.Node.FireVMM.Provider.target_arch() :: {:ok, String.t()} | {:error, {:unsupported_arch, String.t()}}` — returns `"x86_64"` or `"aarch64"`.

- [ ] **Step 1: Write the failing test**

Create `test/hyper/node/fire_vmm/provider_test.exs`:

```elixir
defmodule Hyper.Node.FireVMM.ProviderTest do
  use ExUnit.Case, async: true

  alias Hyper.Node.FireVMM.Provider

  test "target_arch/0 returns a supported architecture on this host" do
    assert {:ok, arch} = Provider.target_arch()
    assert arch in ["x86_64", "aarch64"]
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/hyper/node/fire_vmm/provider_test.exs`
Expected: FAIL — `Hyper.Node.FireVMM.Provider` is undefined.

- [ ] **Step 3: Create the module with `target_arch/0`**

Create `lib/hyper/node/fire_vmm/provider.ex`:

```elixir
defmodule Hyper.Node.FireVMM.Provider do
  @moduledoc """
  Downloads and installs the firecracker + jailer binaries for the current
  architecture into `Hyper.Config.firecracker_install_dir/0`
  (`<work_dir>/redist/firecracker`).

  `ensure_installed/1` is idempotent: if the binaries for the pinned version are
  already present and executable it returns `:ok` without touching the network.
  Otherwise it downloads the official firecracker release tarball for the
  detected architecture into a temporary directory, verifies its SHA-256 against
  a pinned digest, extracts it, copies `firecracker` and `jailer` into the
  install dir, and removes the temporary directory (always, via `try/after`).

  The checksum is pinned here on purpose: downloading the `*.sha256.txt` from the
  same host as the tarball would be trust-on-first-use and provide no real
  integrity guarantee. Pinning the digest is what makes the check meaningful.
  """

  @version "1.16.0"

  # SHA-256 of the official release tarballs, pinned per architecture. Contents
  # of firecracker-v<ver>-<arch>.tgz.sha256.txt from the GitHub release.
  @checksums %{
    "x86_64" => "bd04e26952d4e158085778c6230a0b383d2619c319182e27eaa9d61a212e92d6",
    "aarch64" => "531c713cdbc37d4b8bc2533d851aabc0267096afa1768086a37672abb668efd7"
  }

  @github_base "https://github.com/firecracker-microvm/firecracker/releases/download"

  @doc "Detect the firecracker arch string for the current machine."
  @spec target_arch() :: {:ok, String.t()} | {:error, {:unsupported_arch, String.t()}}
  def target_arch do
    sys = to_string(:erlang.system_info(:system_architecture))

    cond do
      String.contains?(sys, "x86_64") -> {:ok, "x86_64"}
      String.contains?(sys, "amd64") -> {:ok, "x86_64"}
      String.contains?(sys, "aarch64") -> {:ok, "aarch64"}
      String.contains?(sys, "arm64") -> {:ok, "aarch64"}
      true -> {:error, {:unsupported_arch, sys}}
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/hyper/node/fire_vmm/provider_test.exs`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add lib/hyper/node/fire_vmm/provider.ex test/hyper/node/fire_vmm/provider_test.exs
git commit -m "feat: add FireVMM.Provider with arch detection"
```

---

### Task 4: `Provider.sha256_file/1` and `verify_checksum/2`

**Files:**
- Modify: `lib/hyper/node/fire_vmm/provider.ex`
- Test: `test/hyper/node/fire_vmm/provider_test.exs`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `Provider.sha256_file(Path.t()) :: String.t()` — streaming SHA-256, lowercase hex.
  - `Provider.verify_checksum(Path.t(), String.t()) :: :ok | {:error, {:checksum_mismatch, expected :: String.t(), actual :: String.t()}}`

- [ ] **Step 1: Write the failing tests**

Add to `test/hyper/node/fire_vmm/provider_test.exs` (inside the module):

```elixir
  describe "checksums" do
    setup do
      dir = Path.join(System.tmp_dir!(), "provider-sha-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "sha256_file/1 matches :crypto over the whole file", %{dir: dir} do
      path = Path.join(dir, "blob.bin")
      bytes = :binary.copy(<<0, 1, 2, 3, 4, 5, 6, 7>>, 100_000)
      File.write!(path, bytes)

      expected =
        :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

      assert Provider.sha256_file(path) == expected
    end

    test "verify_checksum/2 returns :ok on match", %{dir: dir} do
      path = Path.join(dir, "ok.bin")
      File.write!(path, "hello")
      sha = Provider.sha256_file(path)
      assert :ok = Provider.verify_checksum(path, sha)
    end

    test "verify_checksum/2 returns an error tuple on mismatch", %{dir: dir} do
      path = Path.join(dir, "bad.bin")
      File.write!(path, "hello")
      actual = Provider.sha256_file(path)

      assert {:error, {:checksum_mismatch, "deadbeef", ^actual}} =
               Provider.verify_checksum(path, "deadbeef")
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/hyper/node/fire_vmm/provider_test.exs`
Expected: FAIL — `sha256_file/1` and `verify_checksum/2` are undefined.

- [ ] **Step 3: Implement the functions**

Add to `lib/hyper/node/fire_vmm/provider.ex` (before the final `end`):

```elixir
  @doc "Verify the SHA-256 of `path` equals `expected` (lowercase hex)."
  @spec verify_checksum(Path.t(), String.t()) ::
          :ok | {:error, {:checksum_mismatch, String.t(), String.t()}}
  def verify_checksum(path, expected) do
    actual = sha256_file(path)

    if actual == expected do
      :ok
    else
      {:error, {:checksum_mismatch, expected, actual}}
    end
  end

  @doc "Streaming SHA-256 of a file, returned as lowercase hex."
  @spec sha256_file(Path.t()) :: String.t()
  def sha256_file(path) do
    path
    |> File.open!([:read, :binary, :raw], fn io -> hash_io(io, :crypto.hash_init(:sha256)) end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  # Fold the file through the hash context in 2 MiB chunks.
  defp hash_io(io, ctx) do
    case :file.read(io, 2 * 1024 * 1024) do
      {:ok, data} -> hash_io(io, :crypto.hash_update(ctx, data))
      :eof -> ctx
    end
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/hyper/node/fire_vmm/provider_test.exs`
Expected: PASS (4 tests total).

- [ ] **Step 5: Commit**

```bash
git add lib/hyper/node/fire_vmm/provider.ex test/hyper/node/fire_vmm/provider_test.exs
git commit -m "feat: streaming sha256 + checksum verification in Provider"
```

---

### Task 5: `Provider.extract_and_install/3`

**Files:**
- Modify: `lib/hyper/node/fire_vmm/provider.ex`
- Test: `test/hyper/node/fire_vmm/provider_test.exs`

**Interfaces:**
- Consumes: a `.tgz` whose layout is `release-v<ver>-<arch>/{firecracker-v<ver>-<arch>,jailer-v<ver>-<arch>}`.
- Produces: `Provider.extract_and_install(tar_path :: Path.t(), arch :: String.t(), install_dir :: Path.t()) :: :ok | {:error, {:extract_failed, term()} | {:missing_binary, Path.t()}}`. On success: `install_dir/firecracker`, `install_dir/jailer` (mode `0o755`), and `install_dir/.fc-version` (contents = `@version`) exist.

- [ ] **Step 1: Write the failing test**

Add to `test/hyper/node/fire_vmm/provider_test.exs` (inside the module). Note the shared `build_tarball/2` helper — it is reused by Task 7, so define it as a private function in the test module:

```elixir
  describe "extract_and_install/3" do
    setup do
      dir = Path.join(System.tmp_dir!(), "provider-extract-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "extracts the tarball and installs both binaries + marker", %{dir: dir} do
      arch = "x86_64"
      tar = build_tarball(dir, arch)
      install = Path.join(dir, "install")

      assert :ok = Provider.extract_and_install(tar, arch, install)

      assert File.read!(Path.join(install, "firecracker")) == "FIRECRACKER-BINARY"
      assert File.read!(Path.join(install, "jailer")) == "JAILER-BINARY"
      assert File.read!(Path.join(install, ".fc-version")) == "1.16.0"
      assert Hyper.Sys.Posix.executable?(Path.join(install, "firecracker"))
      assert Hyper.Sys.Posix.executable?(Path.join(install, "jailer"))
    end

    test "returns missing_binary when the tarball lacks the expected layout", %{dir: dir} do
      arch = "x86_64"
      tar = Path.join(dir, "empty.tgz")
      :ok = :erl_tar.create(String.to_charlist(tar), [], [:compressed])
      install = Path.join(dir, "install")

      assert {:error, {:missing_binary, _path}} =
               Provider.extract_and_install(tar, arch, install)
    end
  end

  # Build a fixture .tgz mirroring the real firecracker release layout:
  # release-v1.16.0-<arch>/{firecracker,jailer}-v1.16.0-<arch>
  defp build_tarball(dir, arch) do
    base = "release-v1.16.0-#{arch}"
    src = Path.join(dir, base)
    File.mkdir_p!(src)

    fc = Path.join(src, "firecracker-v1.16.0-#{arch}")
    jail = Path.join(src, "jailer-v1.16.0-#{arch}")
    File.write!(fc, "FIRECRACKER-BINARY")
    File.write!(jail, "JAILER-BINARY")

    tar = Path.join(dir, "firecracker-#{arch}.tgz")

    entries = [
      {String.to_charlist("#{base}/firecracker-v1.16.0-#{arch}"), String.to_charlist(fc)},
      {String.to_charlist("#{base}/jailer-v1.16.0-#{arch}"), String.to_charlist(jail)}
    ]

    :ok = :erl_tar.create(String.to_charlist(tar), entries, [:compressed])
    tar
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/hyper/node/fire_vmm/provider_test.exs`
Expected: FAIL — `extract_and_install/3` is undefined.

- [ ] **Step 3: Implement `extract_and_install/3`**

Add to `lib/hyper/node/fire_vmm/provider.ex` (before the final `end`):

```elixir
  @doc """
  Extract `tar_path` into a sibling `extract/` dir and copy the firecracker +
  jailer binaries into `install_dir`, writing the version marker on success.
  """
  @spec extract_and_install(Path.t(), String.t(), Path.t()) ::
          :ok | {:error, {:extract_failed, term()} | {:missing_binary, Path.t()}}
  def extract_and_install(tar_path, arch, install_dir) do
    extract_dir = Path.join(Path.dirname(tar_path), "extract")
    File.mkdir_p!(extract_dir)

    case :erl_tar.extract(String.to_charlist(tar_path),
           [:compressed, {:cwd, String.to_charlist(extract_dir)}]) do
      :ok -> install_binaries(extract_dir, arch, install_dir)
      {:error, reason} -> {:error, {:extract_failed, reason}}
    end
  end

  defp install_binaries(extract_dir, arch, install_dir) do
    base = "release-v#{@version}-#{arch}"
    fc_src = Path.join([extract_dir, base, "firecracker-v#{@version}-#{arch}"])
    jail_src = Path.join([extract_dir, base, "jailer-v#{@version}-#{arch}"])

    with :ok <- check_exists(fc_src),
         :ok <- check_exists(jail_src) do
      File.mkdir_p!(install_dir)
      install_one(fc_src, Path.join(install_dir, "firecracker"))
      install_one(jail_src, Path.join(install_dir, "jailer"))
      File.write!(Path.join(install_dir, ".fc-version"), @version)
      :ok
    end
  end

  defp check_exists(path) do
    if File.regular?(path), do: :ok, else: {:error, {:missing_binary, path}}
  end

  defp install_one(src, dest) do
    File.cp!(src, dest)
    File.chmod!(dest, 0o755)
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/hyper/node/fire_vmm/provider_test.exs`
Expected: PASS (6 tests total).

- [ ] **Step 5: Commit**

```bash
git add lib/hyper/node/fire_vmm/provider.ex test/hyper/node/fire_vmm/provider_test.exs
git commit -m "feat: tarball extraction + binary install in Provider"
```

---

### Task 6: `Provider.installed?/1`

**Files:**
- Modify: `lib/hyper/node/fire_vmm/provider.ex`
- Test: `test/hyper/node/fire_vmm/provider_test.exs`

**Interfaces:**
- Consumes: an install dir possibly containing `firecracker`, `jailer`, `.fc-version`.
- Produces: `Provider.installed?(install_dir :: Path.t()) :: boolean()` — `true` iff both binaries are executable AND `.fc-version` equals `@version`.

- [ ] **Step 1: Write the failing tests**

Add to `test/hyper/node/fire_vmm/provider_test.exs` (inside the module):

```elixir
  describe "installed?/1" do
    setup do
      dir = Path.join(System.tmp_dir!(), "provider-installed-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    defp seed_install(dir, version) do
      File.mkdir_p!(dir)
      fc = Path.join(dir, "firecracker")
      jail = Path.join(dir, "jailer")
      File.write!(fc, "x")
      File.write!(jail, "x")
      File.chmod!(fc, 0o755)
      File.chmod!(jail, 0o755)
      File.write!(Path.join(dir, ".fc-version"), version)
      dir
    end

    test "true when both binaries are executable and the marker matches", %{dir: dir} do
      assert Provider.installed?(seed_install(dir, "1.16.0"))
    end

    test "false when the version marker does not match", %{dir: dir} do
      refute Provider.installed?(seed_install(dir, "1.15.0"))
    end

    test "false when binaries are absent", %{dir: dir} do
      refute Provider.installed?(dir)
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/hyper/node/fire_vmm/provider_test.exs`
Expected: FAIL — `installed?/1` is undefined.

- [ ] **Step 3: Implement `installed?/1`**

Add to `lib/hyper/node/fire_vmm/provider.ex` (before the final `end`):

```elixir
  @doc "Whether the pinned-version binaries are already installed and executable."
  @spec installed?(Path.t()) :: boolean()
  def installed?(install_dir) do
    fc = Path.join(install_dir, "firecracker")
    jail = Path.join(install_dir, "jailer")
    marker = Path.join(install_dir, ".fc-version")

    Hyper.Sys.Posix.executable?(fc) and
      Hyper.Sys.Posix.executable?(jail) and
      File.read(marker) == {:ok, @version}
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/hyper/node/fire_vmm/provider_test.exs`
Expected: PASS (9 tests total).

- [ ] **Step 5: Commit**

```bash
git add lib/hyper/node/fire_vmm/provider.ex test/hyper/node/fire_vmm/provider_test.exs
git commit -m "feat: Provider.installed?/1 version-marker idempotency check"
```

---

### Task 7: `Provider.ensure_installed/1` orchestration

**Files:**
- Modify: `lib/hyper/node/fire_vmm/provider.ex`
- Test: `test/hyper/node/fire_vmm/provider_test.exs`

**Interfaces:**
- Consumes: `target_arch/0`, `installed?/1`, `verify_checksum/2`, `extract_and_install/3`, the `@checksums` map, and (in prod) `Req`.
- Produces:
  - `Provider.ensure_installed(opts :: keyword()) :: :ok | {:error, term()}` — public boot entry. Opts (all default to production values; overridden in tests): `:arch`, `:install_dir`, `:checksums`, `:fetch`.
  - `Provider.tarball_url(arch :: String.t()) :: String.t()`
  - Guarantee: a fresh temp dir is created under `System.tmp_dir!/0`, the tarball is downloaded into it, verified, extracted, and the temp dir is **always** removed (`try/after`), even on checksum mismatch or extraction failure.

- [ ] **Step 1: Write the failing tests**

Add to `test/hyper/node/fire_vmm/provider_test.exs` (inside the module). These reuse `build_tarball/2` from Task 5:

```elixir
  describe "ensure_installed/1" do
    setup do
      dir = Path.join(System.tmp_dir!(), "provider-ensure-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "downloads, verifies, installs, and cleans up the temp dir", %{dir: dir} do
      arch = "x86_64"
      tar = build_tarball(dir, arch)
      sha = Provider.sha256_file(tar)
      install = Path.join(dir, "install")
      test_pid = self()

      fetch = fn _url, dest ->
        send(test_pid, {:dest, dest})
        File.cp!(tar, dest)
        :ok
      end

      assert :ok =
               Provider.ensure_installed(
                 arch: arch,
                 install_dir: install,
                 checksums: %{arch => sha},
                 fetch: fetch
               )

      assert Hyper.Sys.Posix.executable?(Path.join(install, "firecracker"))
      assert Hyper.Sys.Posix.executable?(Path.join(install, "jailer"))

      assert_received {:dest, dest}
      refute File.exists?(Path.dirname(dest)), "temp dir must be cleaned up"
    end

    test "aborts and cleans up on checksum mismatch, installing nothing", %{dir: dir} do
      arch = "x86_64"
      tar = build_tarball(dir, arch)
      install = Path.join(dir, "install")
      test_pid = self()

      fetch = fn _url, dest ->
        send(test_pid, {:dest, dest})
        File.cp!(tar, dest)
        :ok
      end

      assert {:error, {:checksum_mismatch, _, _}} =
               Provider.ensure_installed(
                 arch: arch,
                 install_dir: install,
                 checksums: %{arch => "deadbeef"},
                 fetch: fetch
               )

      assert_received {:dest, dest}
      refute File.exists?(Path.dirname(dest)), "temp dir must be cleaned up"
      refute File.exists?(Path.join(install, "firecracker"))
    end

    test "is idempotent: skips download when already installed", %{dir: dir} do
      arch = "x86_64"
      install = seed_install(Path.join(dir, "install"), "1.16.0")

      fetch = fn _url, _dest -> flunk("should not download when already installed") end

      assert :ok =
               Provider.ensure_installed(
                 arch: arch,
                 install_dir: install,
                 checksums: %{arch => "unused"},
                 fetch: fetch
               )
    end

    test "errors on unsupported arch", %{dir: dir} do
      install = Path.join(dir, "install")

      assert {:error, {:unsupported_arch, "sparc"}} =
               Provider.ensure_installed(
                 arch: "sparc",
                 install_dir: install,
                 checksums: %{},
                 fetch: fn _, _ -> :ok end
               )
    end

    test "tarball_url/1 builds the official release URL" do
      assert Provider.tarball_url("x86_64") ==
               "https://github.com/firecracker-microvm/firecracker/releases/download/v1.16.0/firecracker-v1.16.0-x86_64.tgz"
    end
  end
```

> Note: `seed_install/2` is defined in the `installed?/1` describe block (Task 6). If your test runner scopes it there, lift `seed_install/2` to a module-level `defp` so both describe blocks can call it.

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/hyper/node/fire_vmm/provider_test.exs`
Expected: FAIL — `ensure_installed/1` and `tarball_url/1` are undefined.

- [ ] **Step 3: Implement the orchestrator**

Add to `lib/hyper/node/fire_vmm/provider.ex` (before the final `end`):

```elixir
  @doc """
  Ensure the firecracker + jailer binaries are installed for this node.

  Idempotent: returns `:ok` immediately if the pinned version is already
  installed. Otherwise downloads, verifies, extracts, and installs, always
  cleaning up the temporary directory.

  Options (default to production values; overridden in tests):

    * `:arch` - target architecture string (default: `target_arch/0`)
    * `:install_dir` - install location (default: `Hyper.Config.firecracker_install_dir/0`)
    * `:checksums` - `%{arch => sha256_hex}` (default: pinned `@checksums`)
    * `:fetch` - `(url, dest_path -> :ok | {:error, term})` (default: `Req`)
  """
  @spec ensure_installed(keyword()) :: :ok | {:error, term()}
  def ensure_installed(opts \\ []) do
    install_dir = Keyword.get(opts, :install_dir, Hyper.Config.firecracker_install_dir())

    with {:ok, arch} <- resolve_arch(opts) do
      if installed?(install_dir) do
        :ok
      else
        do_install(arch, install_dir, opts)
      end
    end
  end

  @doc false
  @spec tarball_url(String.t()) :: String.t()
  def tarball_url(arch) do
    "#{@github_base}/v#{@version}/firecracker-v#{@version}-#{arch}.tgz"
  end

  defp resolve_arch(opts) do
    case Keyword.fetch(opts, :arch) do
      {:ok, arch} -> {:ok, arch}
      :error -> target_arch()
    end
  end

  defp do_install(arch, install_dir, opts) do
    checksums = Keyword.get(opts, :checksums, @checksums)
    fetch = Keyword.get(opts, :fetch, &default_fetch/2)

    with {:ok, expected} <- fetch_checksum(checksums, arch) do
      tmp = make_tmp_dir!()

      try do
        tar = Path.join(tmp, "firecracker-#{arch}.tgz")

        with :ok <- fetch.(tarball_url(arch), tar),
             :ok <- verify_checksum(tar, expected),
             :ok <- extract_and_install(tar, arch, install_dir) do
          :ok
        end
      after
        File.rm_rf!(tmp)
      end
    end
  end

  defp fetch_checksum(checksums, arch) do
    case Map.fetch(checksums, arch) do
      {:ok, sha} -> {:ok, sha}
      :error -> {:error, {:unsupported_arch, arch}}
    end
  end

  defp make_tmp_dir! do
    dir = Path.join(System.tmp_dir!(), "hyper-firecracker-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  defp default_fetch(url, dest_path) do
    case Req.get(url, into: File.stream!(dest_path), redirect: true, max_redirects: 5) do
      {:ok, %Req.Response{status: 200}} -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, {:download_failed, status}}
      {:error, reason} -> {:error, {:download_error, reason}}
    end
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/hyper/node/fire_vmm/provider_test.exs`
Expected: PASS (14 tests total).

- [ ] **Step 5: Compile with warnings as errors**

Run: `mix compile --warnings-as-errors`
Expected: success (no unused-variable / undefined warnings).

- [ ] **Step 6: Commit**

```bash
git add lib/hyper/node/fire_vmm/provider.ex test/hyper/node/fire_vmm/provider_test.exs
git commit -m "feat: Provider.ensure_installed orchestration with temp-dir cleanup"
```

---

### Task 8: Wire the provider into node boot + offline test fixtures

**Files:**
- Modify: `lib/hyper/node.ex:63-70` (`test_system/0`)
- Modify: `lib/hyper/node/fire_vmm/jailer.ex:16-18` (moduledoc only)
- Create: `test/support/firecracker_work_dir/redist/firecracker/firecracker`
- Create: `test/support/firecracker_work_dir/redist/firecracker/jailer`
- Create: `test/support/firecracker_work_dir/redist/firecracker/.fc-version`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: `Hyper.Node.FireVMM.Provider.ensure_installed/0`.
- Produces: node boot installs firecracker before running jailer checks. On the user's dev/prod machine this downloads on first boot; in test it is a no-op because the install dir is pre-seeded with offline fixtures whose `.fc-version` matches `@version`.

- [ ] **Step 1: Create the offline test fixtures**

These must exist at checkout (the OTP app boots `Hyper.Node` before `test_helper.exs` runs, so seeding cannot happen at test time). The `.fc-version` MUST be exactly `1.16.0` with no trailing newline so it matches `Provider`'s `@version`.

Run:

```bash
mkdir -p test/support/firecracker_work_dir/redist/firecracker
printf '#!/bin/sh\nexit 0\n' > test/support/firecracker_work_dir/redist/firecracker/firecracker
printf '#!/bin/sh\nexit 0\n' > test/support/firecracker_work_dir/redist/firecracker/jailer
chmod +x test/support/firecracker_work_dir/redist/firecracker/firecracker
chmod +x test/support/firecracker_work_dir/redist/firecracker/jailer
printf '1.16.0' > test/support/firecracker_work_dir/redist/firecracker/.fc-version
```

Verify the marker has no newline:

Run: `wc -c test/support/firecracker_work_dir/redist/firecracker/.fc-version`
Expected: `6` bytes.

- [ ] **Step 2: Ignore runtime subdirs created under the test work dir**

The jailer checks call `ensure_writable_dir(chroot_base())` which `mkdir -p`s `jails/` under the work dir at boot; `socks/` and `scratch/` may also appear. Keep them out of git. Append to `.gitignore`:

```gitignore
# Runtime dirs created under the test firecracker work dir
/test/support/firecracker_work_dir/jails/
/test/support/firecracker_work_dir/socks/
/test/support/firecracker_work_dir/scratch/
```

- [ ] **Step 3: Wire `ensure_installed/0` into `Hyper.Node.test_system/0`**

In `lib/hyper/node.ex`, replace the `test_system/0` body (`lib/hyper/node.ex:63-70`) so the provider runs first:

```elixir
  @spec test_system :: :ok | {:error, term()}
  def test_system do
    with :ok <- Hyper.Node.FireVMM.Provider.ensure_installed(),
         :ok <- Hyper.Node.Users.test_system(),
         :ok <- Hyper.Node.Layer.Repo.test_system(),
         :ok <- Hyper.Sys.Linux.Dmsetup.test_system() do
      Hyper.Node.FireVMM.test_system()
    end
  end
```

- [ ] **Step 4: Update the jailer moduledoc**

In `lib/hyper/node/fire_vmm/jailer.ex`, replace the host-config sentence in the moduledoc (`lib/hyper/node/fire_vmm/jailer.ex:16-17`):

```elixir
  Host config: paths are derived from `config :hyper, work_dir: ...`. The
  firecracker + jailer binaries are installed under `<work_dir>/redist/firecracker`
  by `Hyper.Node.FireVMM.Provider`; the chroot base is `<work_dir>/jails`.
```

- [ ] **Step 5: Run the full suite (offline)**

Run: `mix test`
Expected: PASS — `Hyper.Node` boots using the seeded fixtures (no network), the new `Provider`/`Config` tests pass, and the existing `node_test.exs` still passes.

- [ ] **Step 6: Compile with warnings as errors**

Run: `mix compile --warnings-as-errors`
Expected: success.

- [ ] **Step 7: Commit**

```bash
git add lib/hyper/node.ex lib/hyper/node/fire_vmm/jailer.ex .gitignore test/support/firecracker_work_dir
git commit -m "feat: install firecracker via Provider on node boot"
```

---

## Self-Review

**1. Spec coverage:**
- Remove hard-coded `jailer_bin`/`firecracker_bin` → Task 2 (removed from `config.exs`, derived in `Config`).
- New `hyper/node/fire_vmm/provider.ex` downloading firecracker tarball per-arch and installing → Tasks 3–7.
- Remove `jailer_chroot_base`, `socket_dir`, `scratch_dir`; replace with one `:work_dir` → Task 2.
- Download into `<work_dir>/redist/firecracker` → `Config.firecracker_install_dir/0` (Task 2) + `extract_and_install/3` (Task 5) + boot wiring (Task 8).
- SHA sum checked for the download → pinned `@checksums` + `verify_checksum/2` (Task 4), enforced before extraction (Task 7).
- Download + SHA in a temp directory, then clean up → `make_tmp_dir!/0` + `try/after File.rm_rf!` (Task 7), asserted by the cleanup tests.
- x86 / aarch64 support → `target_arch/0` (Task 3) + per-arch `@checksums`/URL.

**2. Placeholder scan:** No `TODO`/`TBD`/"handle errors"/"similar to" placeholders; every code step shows complete code. The two pinned digests and the version are real values.

**3. Type consistency:** `target_arch/0`, `sha256_file/1`, `verify_checksum/2`, `extract_and_install/3`, `installed?/1`, `ensure_installed/1`, `tarball_url/1` are named identically in their defining task, their `Interfaces` blocks, and every call site (tests, `do_install/3`, `Hyper.Node.test_system/0`). `Config` accessor names (`firecracker_bin/0`, `jailer_bin/0`, `chroot_base/0`, `socket_dir/0`, `scratch_dir/0`) are unchanged, so `jailer.ex` needs no code change. The `.fc-version` marker value (`@version = "1.16.0"`) is consistent between `installed?/1`, `extract_and_install/3`, and the Task 8 fixture.
