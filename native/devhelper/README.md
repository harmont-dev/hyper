# hyper-devhelper

A tiny setuid-root helper so the unprivileged Hyper node can run the few
device commands it needs (`losetup`, `dmsetup`, `blockdev`) without running as
root wholesale.

## Build & install

```sh
cd native/devhelper
cargo build --release
sudo install -o root -g root -m 4755 \
  target/release/hyper-devhelper /usr/local/bin/hyper-devhelper
```

Then point Hyper at it (runtime config). In helper mode the tool paths must be
absolute (the helper execs the path passed via `--bin`):

```elixir
# config/runtime.exs (or per-host config)
config :hyper,
  device_helper: "/usr/local/bin/hyper-devhelper",
  losetup_path: "/usr/sbin/losetup",
  dmsetup_path: "/usr/sbin/dmsetup",
  blockdev_path: "/usr/sbin/blockdev"
```

With `device_helper` unset, Hyper runs the tools directly — fine when the node
itself runs as root (dev); bare names on `$PATH` are OK there.

The caller supplies the binary via `--bin`, but the helper verifies it before
exec: absolute path, basename matching the subcommand, and **root-owned, not
group/other-writable, not a symlink**. Those last checks are what make a
caller-supplied path safe — an unprivileged caller can't point it at a binary it
controls. It then execs with a cleared environment (no `PATH` needed).

## What it allows

Only the exact command shapes Hyper issues — each validated arg-by-arg:

- `losetup --find --show [--read-only] <abs-path>` and `losetup -d /dev/loopN`
- `dmsetup create <hyper-*> [--readonly] --table "0 <n> snapshot <o> <c> P|N <chunk>"`
- `dmsetup remove --retry <hyper-*>`
- `blockdev --getsz <abs-path>`

dm device names must be `hyper-*`; dm tables must be **snapshot** targets only
(no `linear`/`crypt`/etc. that could map arbitrary devices); paths must be
absolute with no `..`. Anything else exits non-zero without running.

The environment is **cleared** before exec (fixed `PATH` only) — a setuid binary
must never pass the caller's env (LD_PRELOAD/LD_LIBRARY_PATH) into a root process.

Real tools are exec'd from `/usr/sbin/<tool>`; adjust if your distro installs
them elsewhere.

## Intentional looseness

- Paths are validated as absolute / no-traversal but not pinned to a specific
  prefix (the layer/scratch dirs are Hyper config, not known to this binary). If
  you want a hard prefix lock, bake `layer_dir`/`scratch_dir` in at build time.
