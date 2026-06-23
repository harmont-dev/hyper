# Contributing to Hyper

Thanks for your interest in Hyper. Contributions are welcome, but please read
this document first -- Hyper is a technical-first project with a high quality
bar and a few non-obvious requirements.

## Before you start

By submitting a contribution (a pull request, patch, or commit) you agree to
the [Contributor License Agreement](CLA.md). In short: **you assign copyright
in your contribution to the project owner**, who keeps the copyright
consolidated so Hyper can be relicensed or dual-licensed in the future. You
retain a perpetual license to your own work. If you are contributing on company
time, make sure you have permission to do so. If you do not agree with the CLA,
please do not submit a contribution.

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
Linux can never move off GPLv2. Consolidating copyright under a single owner
avoids that trap and lets Hyper:

- **Relicense in the future** if the AGPL stops serving the project.
- **Offer commercial licenses** to organizations that cannot use AGPL code,
  which is how development gets funded. You can only sell what you wholly own.
- **Enforce the license** against infringers without coordinating dozens of
  copyright holders.

Yes, this is asymmetric: the owner reserves the right to license Hyper
proprietarily, which the AGPL denies everyone else. That is the deal open-core
projects make, and we would rather state it plainly than bury it. In exchange,
the CLA grants you a perpetual license to keep using your own contributions for
any purpose (CLA §3) -- you never lose the right to the work you authored.

If assigning copyright is not something you are willing to do, that is a
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
