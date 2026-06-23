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

## Cutting a release

1. Bump the version **in both manifests** to the same value:
   - `native/suidhelper/Cargo.toml` → `[package] version = "X.Y.Z"`
   - `mix.exs` → `version: "X.Y.Z"`
2. Verify locally before tagging:
   ```bash
   bash .github/scripts/check-versions.sh X.Y.Z
   ```
3. Commit, then tag and push:
   ```bash
   git commit -am "release: vX.Y.Z"
   git tag vX.Y.Z
   git push origin main vX.Y.Z
   ```
4. The workflow builds both packages and creates a **draft** GitHub Release
   automatically. The `publish-crate` and `publish-hex` jobs then wait for
   approval — approve them in the run's *Review deployments* prompt.
5. Once both publishes succeed, the draft release is flipped to published
   automatically.

## Notes

- A given version can be published to crates.io / Hex exactly once. If a
  publish fails after the other succeeded, fix forward with a new patch version
  rather than retrying the same tag.
- The version guard (`check-versions.sh`) fails the whole run if the tag and the
  two manifests disagree, so a typo never reaches a registry.

[crates.io]: https://crates.io/crates/hyper-suidhelper
[Hex]: https://hex.pm/packages/hypervm
