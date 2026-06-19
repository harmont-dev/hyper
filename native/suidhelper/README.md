# hyper-suidhelper

A tiny setuid-root helper so the unprivileged Hyper node can run the few
device commands it needs (`losetup`, `dmsetup`, `blockdev`) without running as
root wholesale.

## Build & install

Static **musl** binaries for both server arches. The toolchain and targets are
pinned in `rust-toolchain.toml` (nightly + both musl targets), and aarch64
cross-links via the toolchain's bundled `rust-lld` — no external cross toolchain
is required:

```sh
cd native/suidhelper
cargo build --release --target x86_64-unknown-linux-musl
cargo build --release --target aarch64-unknown-linux-musl
```

Both are statically linked (no libc dependency on the target host). Install the
one matching the host, setuid root:

```sh
sudo install -o root -g root -m 4755 \
  target/x86_64-unknown-linux-musl/release/hyper-suidhelper /usr/local/bin/hyper-suidhelper
```

Then point Hyper at it (runtime config). The tool paths must be absolute (the
helper execs the path passed via `--bin`):

```elixir
# config/runtime.exs (or per-host config)
config :hyper,
  suid_helper: "/usr/local/bin/hyper-suidhelper",
  losetup_path: "/usr/sbin/losetup",
  dmsetup_path: "/usr/sbin/dmsetup",
  blockdev_path: "/usr/sbin/blockdev"
```

The helper is mandatory — Hyper always routes device ops through it.

## CLI

One subcommand per tool, each taking its own `--bin`. Every result is a single
JSON line on stdout; errors go to stderr with exit code 2.

```sh
hyper-suidhelper losetup  --bin /usr/sbin/losetup  attach <abs-path>   # → {"result":"attached","device":"/dev/loopN"}
hyper-suidhelper losetup  --bin /usr/sbin/losetup  detach /dev/loopN   # → {"result":"detached"}
hyper-suidhelper dmsetup  --bin /usr/sbin/dmsetup  create <hyper-*> [--readonly] --table "0 <n> snapshot <o> <c> P|N <chunk>"
hyper-suidhelper dmsetup  --bin /usr/sbin/dmsetup  remove [--retry] <hyper-*>
hyper-suidhelper blockdev --bin /usr/sbin/blockdev --getsz <dev>       # → {"sectors":N}
hyper-suidhelper sys-test                                              # → {"sys_test":"ok"}
```

`losetup attach` is always read-only. Mutable layers are out of scope (handled
elsewhere via dm-thin), so there is no read-write attach.

## Security posture

- **Privilege window is one syscall.** At startup a `.preinit_array` constructor
  drops euid to the real (caller's) uid before `main`. Root is re-acquired only
  inside a `Privileged` RAII guard that wraps exactly the `Command` spawn; the
  guard drops back on scope exit, so argument parsing and output parsing never
  run as root.
- **`--bin` is validated, not trusted.** It must be an absolute path whose
  basename matches the subcommand, and a **root-owned, non-symlink, not
  group/other-writable** regular file. An unprivileged caller therefore can't
  point it at a binary it controls. The tool is exec'd with a cleared
  environment (no `LD_PRELOAD`/`PATH` inheritance).
- **Operands are validated by type, at parse time.** Loop devices must be
  `/dev/loopN`; block operands must be a loop or a `/dev/mapper/hyper-*` device;
  dm names must be `hyper-*`; backing files must canonicalize under `/srv/hyper`
  and are pinned by fd (`/proc/self/fd/N`) to close the TOCTOU window; dm tables
  must be **snapshot** targets only (no `linear`/`crypt`/… that could map
  arbitrary devices). The device path checks reject `..` traversal. Anything
  else exits non-zero without running.
