<p align="center">
  <img src="docs/res/Hyper-Banner.png" alt="Hyper" />
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

<!-- TODO(markovejnovic): Deeper quick start -->

Please read the [Hexdocs](https://hyper.hexdocs.pm/) for guides on using,
deploying and integrating Hyper.

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
- gRPC Interface -- although the author exclusively uses Hyper through the
  BEAM-native interfaces, we recognize this may not be ideal for all languages
  and existing stacks. For that reason, Hyper has a GRPC interface, so you can
  call it from any language you already use.

## Docs

Full docs on getting started, as well as useful diagrams are available on
[Hexdocs](https://hyper.hexdocs.pm/).

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
  consequently we will not be providing you with direct support, SDKs, etc.
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
  
## License

Hyper is licensed under the GNU Affero General Public License v3.0 or later
(AGPL-3.0-or-later). See [LICENSE](LICENSE) and [NOTICE](NOTICE). Contributions
are governed by the [Contributor License Agreement](CLA.md).

### Why AGPL?

Hyper is infrastructure meant to be run as a service. If you modify Hyper and
offer it to others over a network, we expect you to share your changes
publicly. The product is built by humans for humans and we want to keep it that
way -- we don't want anyone taking Hyper closed-source and reselling it. Hyper
is free of charge, and we expect you to play nicely with that philosophy. In
practical terms, for most users:

- **Running Hyper as-is internally** imposes no copyleft obligations. You do
  not need to share your source.
- **The VMs and workloads Hyper runs are yours.** Copyleft covers Hyper itself,
  not the things you orchestrate with it. Your code stays your code.
- **Modifying Hyper** and offering any form of product built with it as a
  service, however, **requires** that you make your modifications open-source.
  We wish to make Hyper better, and that means you need to be a part of it.

This section is a plain-language summary, not legally binding. For the
authoritative terms, see [LICENSE](LICENSE).
