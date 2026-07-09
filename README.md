<p align="center">
  <img src="docs/res/Hyper-Banner.png" alt="Hyper" />
</p>

<p align="center">
  <a href="https://hex.pm/packages/hypervm"><img src="https://img.shields.io/hexpm/v/hypervm.svg" alt="Hex.pm version" /></a>
  <a href="https://hexdocs.pm/hypervm/"><img src="https://img.shields.io/badge/docs-hexdocs-purple.svg" alt="Hexdocs" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/hexpm/l/hypervm.svg" alt="License: MIT" /></a>
  <a href="https://github.com/harmont-dev/hyper/commits/main"><img src="https://img.shields.io/github/last-commit/harmont-dev/hyper.svg" alt="Last commit" /></a>
  <a href="https://codecov.io/gh/harmont-dev/hyper"><img src="https://codecov.io/gh/harmont-dev/hyper/branch/main/graph/badge.svg" alt="Coverage" /></a>
  <a href="https://discord.gg/hm-dev"><img src="https://img.shields.io/discord/1503184719578136576?logo=discord&label=discord" alt="Discord" /></a>
  <a href="https://deepwiki.com/harmont-dev/hyper"><img src="https://deepwiki.com/badge.svg" alt="Ask DeepWiki" /></a>
  <img src="https://img.shields.io/badge/elixir-~%3E%201.20-4B275F.svg" alt="Elixir ~> 1.20" />
</p>

_This project is primarily developed by [harmont.dev](https://harmont.dev)
which uses it as the core VM orchestrator._

> **Status:** early and under active development. Interfaces and behavior are
> expected to change.

Hyper is a distributed orchestrator for
[Firecracker](https://firecracker-microvm.github.io/) microVMs. Hyper fits the
same niche as [Daytona](https://github.com/daytonaio/daytona),
[Runloop](https://runloop.ai/) and similar.

## Quick Start

On an Ubuntu/Debian machine with KVM (bare metal, or a cloud instance with
nested virtualization):

```sh
git clone https://github.com/harmont-dev/hyper && cd hyper
./setup.sh    # one-time host provisioning (asks for sudo)
iex -S mix    # boot a Hyper node
```

Then load an OCI image and boot it:

```elixir
{:ok, img_id} = Hyper.Img.OciLoader.load("docker.io/library/alpine:3.19")
{:ok, vm} = Hyper.create_vm(%Hyper.Vm.Spec{img_id: img_id})
{:ok, %{stdout: "hello\n"}} = Hyper.exec(vm, ["/bin/echo", "hello"])
```

That's a real Firecracker microVM with a copy-on-write rootfs -- the
[quickstart guide](https://hexdocs.pm/hypervm/quickstart.html) has the
details. To embed Hyper in your own application instead, add it to your Mix
project:

```elixir
def deps do
  [
    {:hypervm, "~> 0.1"}
  ]
end
```

and follow the [installation
guide](https://hexdocs.pm/hypervm/install.html). The
[Hexdocs](https://hexdocs.pm/hypervm/) cover using, deploying and
integrating Hyper.

## Features

- **Fully distributed** -- nodes that are added to the cluster automatically
  become VM runners.
- **Affinity-based scheduling** -- Hyper automatically schedules new VMs on
  nodes with the most shared resources. Forked VMs prefer being scheduled on
  nodes where the original VM ran, with fallbacks across the cluster.
- **Disk layering** -- Forking virtual machines creates thin COW layers rather
  than full disk snapshots. This gives Hyper a significant performance edge
  over sandbox providers which do not implement this.
- **Telemetry** -- Hyper is mostly fully instrumented with
  [Otel](https://opentelemetry.io/) so you get full traces on if/why things are
  not performing as expected.
- **Minimal stack** -- Hyper makes very few assumptions on your cloud, and only
  requires a Postgres database as a minimal external dependency.
- **🔮 BEAM-native** -- Hyper is written on the
  [BEAM](https://en.wikipedia.org/wiki/BEAM_(Erlang_virtual_machine)). This
  means that fault-tolerance is built into the virtual machine, and allows you
  to interactively debug any issues you run into.
- **gRPC Interface** -- although the author exclusively uses Hyper through the
  BEAM-native interfaces, we recognize this may not be ideal for all languages
  and existing stacks. For that reason, Hyper has a GRPC interface, so you can
  call it from any language you already use.
  ⚠️ The gRPC API is unauthenticated and off by default — bind it to a trusted network or front it with an authenticating proxy. See [the gRPC guide](docs/grpc.md).

## Docs

Full docs on getting started, as well as useful diagrams are available on
[Hexdocs](https://hexdocs.pm/hypervm/). There exists a
[Deepwiki](https://deepwiki.com/harmont-dev/hyper) **but this is AI-generated
and is not the source of truth.** Use the Deepwiki to fill in the blanks where
the Hexdocs are lacking. **We actively urge you to open issues/PRs for missing
Hexdocs documentation.**

## Why?

The reason I have written this is because I was slightly dissatisfied with
existing products. Not to slander any other products (I have a lot of respect
and have built on their shoulders), but here is the rough overview of why I did
not enjoy existing products:

- [Daytona](http://daytona.io/) (the best overall, in my experience) was a
  container-first SAAS. Their recent additions of VMs have been unreliable and
  buggy for me -- between snapshots not getting committed and their VM feature
  not being available open-source, I was ultimately dissatisfied and decided to
  write my own. **Daytona has much better support than Hyper ever will. If you
  do not want to maintain your code and want a Slack channel with really awesome
  people, go with Daytona.** Hyper is a technical-first product, and
  consequently we do not offer guaranteed support, SLAs, or polished SDKs. There
  is a [community Discord](https://discord.gg/hm-dev) where you can ask
  questions, but please do not expect dedicated support.
- [Freestyle.sh](https://www.freestyle.sh/) is amazing in terms of performance,
  and probably beats Hyper on performance alone, however, the incredible
  unreliability has caused me to churn. **If you need raw performance, esp.
  when it comes to forking RAM state, Freestyle is better than Hyper.**
- [Runloop](https://runloop.ai/) is incredibly naive and, based on my
  experience, not much more than a firecracker wrapper. There is no support for
  forking, and Runloop is absurdly expensive for what it's worth.

The reasons to use Hyper are:

- You need good distributed performance. Hyper is designed to scale to
  extremely high numbers of host nodes.
- You do not want limits. All other providers have limits, and although those
  are in place to avoid abuse, I believe that limits should not exist -- just
  charge per compute hour and abuse should be curbed financially. Why can you
  not get a 128-core VM? With Hyper, you can.
- You need good disk forking. Hyper has great support for forking block storage
  and this is designed as a first-party feature. Hyper **does not support RAM
  snapshotting and will not in the foreseeable future**.

## Contributing

Contributions are welcome. Hyper is a technical-first project with a strict
quality gate (`mix check` must pass) and a few Linux/Firecracker prerequisites.
Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

Contributions are accepted under the project's license (MIT): by opening a
pull request you agree that your contribution is licensed under the same terms,
and you retain the copyright to your own work. No separate contributor
agreement is required.

## License

Hyper is licensed under the MIT License. See [LICENSE](LICENSE). Contributions
are accepted under the same license.
