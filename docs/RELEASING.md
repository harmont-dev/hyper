# Releasing

Hyper releases are cut by pushing a `vX.Y.Z` tag, which runs
`.github/workflows/release.yml`. That workflow builds the suidhelper binaries,
builds and publishes the Hex package (`hypervm`), and drafts then publishes a
GitHub release.

## One-time repository setup

These must exist before the first tag, or the pipeline fails:

- **Secret `HEX_API_KEY`** — a Hex API key with publish rights for `hypervm`.
  Create it with `mix hex.user key generate` and add it under
  *Settings → Secrets and variables → Actions*. It must be visible to the
  `release` environment.
- **Environment `release`** — *Settings → Environments → New environment →
  `release`*. The `publish-hex` job is gated on it; add required reviewers here
  if you want a manual approval before anything hits Hex.

## Cutting a release

1. Update `## [Unreleased]` in `CHANGELOG.md` to the new version and date.
2. Set the version in `mix.exs` and every `native/**/Cargo.toml` `[package]`
   (except `xtask`, which stays `0.0.0`) to `X.Y.Z`, and merge to `main`.
   > The pipeline also stamps the tag version into the manifests as a safety
   > net, but tagging a commit **already at** `X.Y.Z` keeps the tag's tree and
   > the published artifacts identical — do that.
3. Tag and push:
   ```sh
   git tag vX.Y.Z && git push origin vX.Y.Z
   ```
4. Watch the `Release` workflow. It leaves a **draft** GitHub release until Hex
   publish succeeds, then flips it live.

## Consumer note

The Hex package ships the native crate **sources**, not prebuilt binaries: the
setuid helper's identity is verified by BLAKE3 against the consumer's own build,
so consumers compile it locally (needs rustup + the pinned nightly, the musl
target, `protoc`, and `protoc-gen-elixir`).
