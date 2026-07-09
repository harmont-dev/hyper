# Quick Start

Boot a real Firecracker microVM on your own Linux machine in about five
minutes.

This is the fastest path to a running Hyper node. It is a dev/eval setup — for
a production install (dedicated system user, managed PostgreSQL, systemd)
follow the [installation guide](install.md).

## What you need

- An Ubuntu/Debian host (x86_64 or aarch64) with KVM — `stat /dev/kvm` must
  succeed. (Other distros work too, via the manual [installation
  guide](install.md).)
- cgroups v2 (the default on any modern distro).
- `sudo` — host provisioning (device-mapper, the setuid helper) needs root.
  Hyper itself never runs as root.
- [Docker](https://docs.docker.com/engine/install/) — for the side-car
  Postgres.
- Elixir `~> 1.20` OTP 28+ ([install](https://elixir-lang.org/install.html)).
- Rust via [rustup](https://rustup.rs) — the build compiles the setuid helper
  and the in-guest agent.

`setup.sh` checks every requirement up front and stops with an actionable
error before touching the host.

## Run it

```sh
git clone https://github.com/harmont-dev/hyper && cd hyper
./setup.sh    # one-time host provisioning (asks for sudo)
              # NOTE: please read this script and ensure you're comfortable
              # with it

iex -S mix    # boot a Hyper node
```

## Boot a VM

In the `iex` shell:

```elixir
{:ok, img_id} = Hyper.Img.OciLoader.load("docker.io/library/alpine:3.19")
{:ok, vm} = Hyper.create_vm(%Hyper.Vm.Spec{img_id: img_id, type: :micro})
{:ok, %{stdout: "hello\n"}} = Hyper.exec(vm, ["/bin/echo", "hello"])
```

That is a real Firecracker microVM with a copy-on-write rootfs. The
[intro](intro.md#usage) walks through loading images, booting VMs, and
running commands; for other languages there is a
[gRPC interface](../grpc.md).

## Where next

- [Intro](intro.md) — concepts and the usage walkthrough.
- [Installation guide](install.md) — the manual, production-grade setup.
- [Configuration guide](config.md) — every `/etc/hyper/config.toml` knob.
