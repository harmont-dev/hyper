# Contributing to Hyper

Thanks for your interest in Hyper. Contributions are welcome, but please read
this document first -- Hyper is a technical-first project with a high quality
bar and a few non-obvious requirements.

## Before you start

By submitting a contribution (a pull request, patch, or commit) you agree to
the [Contributor License Agreement](CLA.md). In short: **you keep the copyright
to your contribution** and grant the project owner a broad, non-exclusive
license — including the right to relicense and dual-license Hyper in the
future. You are not asked to give up ownership of your work. If you are
contributing on company time, make sure you have permission to do so. If you do
not agree with the CLA, please do not submit a contribution.

For anything beyond a small fix, **open an issue first** and describe what you
intend to do. Hyper is opinionated and moves fast; a quick discussion avoids
wasted work on a PR that does not fit the direction of the project.

### Why a CLA?

Hyper is released under the AGPL, but it is also the commercial backbone of
[harmont.dev](https://harmont.dev). The CLA exists to keep those two facts
compatible.

Under the AGPL, every contributor owns the copyright to their own patches. That
sounds nice, but it means the license can never be changed without tracking down
and getting agreement from every person who ever contributed -- the same reason
Linux can never move off GPLv2. The CLA sidesteps that trap **without taking
your copyright**: you keep ownership, and you grant the owner a broad,
non-exclusive, sublicensable license. That single grant is enough to let Hyper:

- **Relicense in the future** if the AGPL stops serving the project.
- **Offer commercial licenses** to organizations that cannot use AGPL code,
  which is how development gets funded. A sublicensable license lets the owner
  do this without owning your copyright outright.
- **Enforce the license** against infringers from a single party, without
  coordinating dozens of copyright holders.

Yes, this is asymmetric: the owner reserves the right to license Hyper
proprietarily, which the AGPL denies everyone else. That is the deal open-core
projects make, and we would rather state it plainly than bury it. But you are
not signing your work away -- you keep the copyright to everything you author
(CLA §3) and stay free to use it however you like.

If granting that license is not something you are willing to do, that is a
completely reasonable position -- but please do not submit a contribution.

## What we are looking for

- **Bug fixes** with a clear reproduction.
- **Performance work** -- especially around disk forking, scheduling, and
  distribution. Bring numbers.
- **Correctness and fault-tolerance** improvements.
- **Documentation** -- guides, `@moduledoc`s, and architecture notes.

## Prerequisites

Hyper runs Firecracker microVMs and leans on Linux primitives (cgroups,
`/proc`, the jailer, a setuid helper). Development that touches the VM stack
therefore requires **Linux**. You will need:

- **Elixir `~> 1.20`** on **Erlang/OTP 28+**.
- **PostgreSQL** -- the image database. The default dev/test config expects a
  database reachable at `localhost` as `postgres`/`postgres` (see
  `config/config.exs`).

Pure unit tests (`test/unit`, `test/controls`) do not need Firecracker, but the
database-backed tests need Postgres.

## Getting set up

```sh
mix deps.get
mix ecto.create
mix ecto.migrate
mix test
```

To run a local cluster, start nodes with matching `--cookie` and the names
configured in `config/config.exs`:

```sh
iex --name a@127.0.0.1 --cookie hyper -S mix
iex --name b@127.0.0.1 --cookie hyper -S mix
```

## The quality gate

Before you open a PR, **`mix check` must pass**. It is the same strict gate the
maintainers run:

```sh
mix check
```

It runs, in order:

1. `mix format --check-formatted` -- formatting is not optional.
2. `mix compile --warnings-as-errors` -- zero warnings.
3. `mix credo --strict` -- static analysis.
4. `mix test --warnings-as-errors` -- the suite.
5. `mix dialyzer` -- type checking.

Add `@spec`s to public functions; Dialyzer is configured strictly
(`:unmatched_returns`, `:extra_return`, `:missing_return`) and will flag
missing or wrong ones.

## Testing philosophy

Write tests that prove behavior, not tests that pad a coverage number. Cover
the real logic and the edge cases that matter; a smoke test that exercises the
happy path is often enough. Do **not** add mechanical, one-assertion-per-getter
tests that exist only to inflate the count -- they will be asked to be removed.
Match the style of the tests already in `test/`.

The `:integration` and `:external` test suites are excluded by default. The `:integration` suite (`test/e2e/`) contains live Firecracker E2E tests that boot real VMs and require a provisioned KVM host (see `docs/cookbook/install.md`) and passwordless sudo. The `:external` suite pulls real OCI images. Both run automatically in CI's `integration` job on every PR, so you do not need to run them locally unless you are developing them -- `mix check` runs the default test set, which is sufficient for most contributions.

## Generated code

The Firecracker API bindings under
`lib/hyper/firecracker/api/{operations,schemas}` are **generated** from the
committed OpenAPI spec in `priv/firecracker/` -- do not hand-edit them. To
regenerate (e.g. after bumping the Firecracker version, which is documented in
the `Mix.Tasks.Compile.FirecrackerGen` moduledoc in `mix.exs`):

```sh
mix firecracker.gen
```

## Commits and pull requests

- Follow [Conventional Commits](https://www.conventionalcommits.org/):
  `feat(scope): ...`, `fix: ...`, `docs: ...`, etc. Scopes match subsystems
  (`feat(firecracker): ...`, `feat(fire_vmm): ...`).
- Keep PRs focused. One logical change per PR.
- Make sure `mix check` passes and the branch is up to date with `main`.
- Explain the *why* in the PR description, not just the *what*.

## Reporting bugs and security issues

Open a GitHub issue for bugs, with the version, your environment, and a minimal
reproduction. For anything security-sensitive, **do not open a public issue**
-- email the maintainer at <marko@harmont.dev> instead.

You can also ask questions in the [community
Discord](https://discord.gg/hm-dev).
