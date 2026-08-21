#!/usr/bin/env bash
# Build the prod release and publish it to GCS as a publicly readable object.
#
# The workers fetch this tarball over plain https with curl and no credentials,
# so "public" is not optional. Uniform bucket-level access is the default on new
# buckets and blocks per-object ACLs entirely, so the object is made readable by
# granting roles/storage.objectViewer to allUsers on the BUCKET.
#
# The tarball is ~42MB. It is built here, on this box: local dev is
# Ubuntu 24.04 / glibc 2.39 and the workers boot ubuntu-2404-lts-amd64, so the
# ERTS + NIFs + the Rust suidhelper in the tarball run unmodified over there.
# That match is load-bearing -- build this on anything older/newer and the
# workers will fail on a glibc symbol at boot.
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

need gcloud
need curl
need mix

TARBALL="$REPO_ROOT/_build/prod/hyper-0.1.0.tar.gz"

say "building prod release (MIX_ENV=prod mix release --overwrite)"
( cd "$REPO_ROOT" && MIX_ENV=prod mix release --overwrite )
[ -f "$TARBALL" ] || die "expected release tarball at $TARBALL, not found"
say "built $(du -h "$TARBALL" | cut -f1) -> $TARBALL"

say "ensuring bucket gs://${BUCKET} exists (project ${PROJECT})"
if gcloud storage buckets describe "gs://${BUCKET}" --project="$PROJECT" >/dev/null 2>&1; then
  say "bucket already exists"
else
  gcloud storage buckets create "gs://${BUCKET}" \
    --project="$PROJECT" --location=US --uniform-bucket-level-access \
    || say "bucket create returned non-zero (already exists?), continuing"
fi

say "granting roles/storage.objectViewer to allUsers on gs://${BUCKET}"
# This is what actually makes the object fetchable without credentials under
# uniform bucket-level access. `gsutil acl set public-read` on the object does
# NOT work on such a bucket -- it errors out.
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
  --project="$PROJECT" \
  --member=allUsers \
  --role=roles/storage.objectViewer >/dev/null

say "uploading tarball -> gs://${BUCKET}/hyper.tar.gz"
gcloud storage cp "$TARBALL" "gs://${BUCKET}/hyper.tar.gz" --project="$PROJECT"

say "verifying the public URL is actually fetchable"
# A 403 here is the single most likely way this demo dies. Surface it NOW,
# loudly, instead of five minutes later inside a worker's startup script where
# the only evidence is a VM that silently never joins the cluster.
# IAM propagation can lag a few seconds, so retry briefly before failing.
ok=0
for attempt in 1 2 3 4 5 6; do
  if curl -fsI --max-time 20 "$RELEASE_URL" >/dev/null 2>&1; then ok=1; break; fi
  say "  not public yet (attempt ${attempt}/6), waiting 5s for IAM to propagate"
  sleep 5
done
[ "$ok" = 1 ] || die "$RELEASE_URL is not publicly fetchable (curl -fsI failed).
Check: gcloud storage buckets get-iam-policy gs://${BUCKET}
and that no org policy (constraints/storage.publicAccessPrevention) forbids public objects."

say "published and verified public:"
printf '\n    %s\n\n' "$RELEASE_URL"
say "next: scripts/demo/20-control-up.sh"
