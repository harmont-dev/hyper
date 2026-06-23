# Releasing Hyper

Hyper ships two artifacts in lockstep from one git tag:

- **`hyper-suidhelper`** — the Rust setuid helper, published to [crates.io] and
  attached to the GitHub Release as static musl binaries for
  `x86_64-unknown-linux-musl` and `aarch64-unknown-linux-musl`.
- **`hypervm`** — the Elixir package, published to [Hex] (package + docs).

Both are driven by `.github/workflows/release.yml`, triggered by pushing a
`vX.Y.Z` tag.

## One-time setup

1. **Repository secrets** (Settings → Secrets and variables → Actions):
   - `CARGO_REGISTRY_TOKEN` — a crates.io API token. Mint at
     <https://crates.io/settings/tokens> with the *publish-update* scope (and
     *publish-new* for the very first release). The crate name
     `hyper-suidhelper` must be available/owned by your account.
   - `HEX_API_KEY` — a Hex API key. Mint with
     `mix hex.user key generate --permission api:write` (or via
     <https://hex.pm/dashboard/keys>). The `hypervm` package must be
     owned by your Hex account.

2. **`release` Environment** (Settings → Environments → New environment →
   `release`): add yourself (or the release team) under *Required reviewers*.
   The `publish-crate` and `publish-hex` jobs target this environment, so they
   pause for manual approval before anything reaches a registry.

3. **Let the workflow push to `main`.** The `prepare-release` job commits the
   version bump and pushes it to `main` using the built-in `GITHUB_TOKEN`. If
   `main` has a branch-protection rule, allow the GitHub Actions bot to bypass
   it (Settings → Branches → the `main` rule → *Allow specified actors to
   bypass required pull requests* → add `github-actions[bot]`), or the push —
   and the release — will fail.

## Cutting a release

The git tag is the **single source of truth** for the version — you do not edit
the manifests by hand. Just tag and push:

```bash
git tag vX.Y.Z
git push origin vX.Y.Z
```

What happens next, automatically:

1. **`prepare-release`** writes `X.Y.Z` into `native/suidhelper/Cargo.toml` and
   `mix.exs`, commits `release: vX.Y.Z`, and pushes it to `main`. Every later
   job builds from that exact commit.
2. Both packages are built and a **draft** GitHub Release is created with the
   binaries, the Hex tarball, and `SHA256SUMS`.
3. **`publish-crate`** and **`publish-hex`** wait for approval as two separate
   `release`-environment deployments — approve both in the run's *Review
   deployments* prompt (you can select them together).
4. Once both publishes succeed, the draft release is flipped to published.

## Notes

- A given version can be published to crates.io / Hex exactly once. If a
  publish fails after the other succeeded, fix forward with a new patch version
  (a new tag) rather than retrying the same one.
- The committed manifest versions are only bookkeeping — the tag always wins.
  `prepare-release` is idempotent: re-running a tag whose bump already landed
  simply skips the commit.

[crates.io]: https://crates.io/crates/hyper-suidhelper
[Hex]: https://hex.pm/packages/hypervm
