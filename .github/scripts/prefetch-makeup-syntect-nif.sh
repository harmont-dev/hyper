#!/usr/bin/env bash
# Pre-seed rustler_precompiled's cache with makeup_syntect's NIF via curl.
#
# rustler_precompiled downloads NIFs with Erlang's :httpc, which refuses
# responses whose headers exceed 10 KiB. GitHub's release-download 302 now
# carries ~10.8 KiB (mostly content-security-policy), so the fetch fails with
# `{:header_too_long, {:max, 10240}}` and compiling the :dev-only docs dep
# aborts `mix compile`. curl has no such cap. This only swaps the transport:
# rustler_precompiled still verifies the cached tarball against the sha256 in
# the dep's checksum file before loading it. Drop this once :httpc (or
# rustler_precompiled) copes with the larger headers.
#
# Run after `mix deps.get`, from the repo root.
set -euo pipefail

dep=deps/makeup_syntect
triple="$(uname -m)-unknown-linux-gnu"

file=$(grep -o "\"libmakeup_syntect-v[^\"]*-${triple}\.so\.tar\.gz\"" \
  "$dep"/checksum-Elixir.MakeupSyntect.exs | tr -d '"')
if [[ -z $file ]]; then
  echo "no makeup_syntect NIF listed for ${triple}" >&2
  exit 1
fi
version=$(sed -E 's/^libmakeup_syntect-v([^-]+)-.*/\1/' <<<"$file")

# :filename.basedir(:user_cache, ...) on Linux, which rustler_precompiled reads.
cache="${XDG_CACHE_HOME:-$HOME/.cache}/rustler_precompiled/precompiled_nifs"
mkdir -p "$cache"
curl -fsSL --retry 3 -o "$cache/$file" \
  "https://github.com/elixir-makeup/makeup_syntect/releases/download/v${version}/${file}"
echo "cached $cache/$file"
