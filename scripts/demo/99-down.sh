#!/usr/bin/env bash
# Tear the whole demo down. THIS IS THE ONE THAT SAVES MONEY.
#
# The autoscaler never scales down on its own, so every worker it created stays
# running -- and billing -- until this deletes it. Run it when the demo ends.
#
# FORCE=1 skips the confirmation prompt. DELETE_BUCKET=1 also removes the GCS
# release bucket (left alone by default -- it is cheap and reusable).
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

need gcloud

FORCE="${FORCE:-0}"
DELETE_BUCKET="${DELETE_BUCKET:-0}"

say "inventorying demo resources in ${PROJECT}"

# Workers are found by LABEL, not by name prefix: the autoscaler labels every
# instance it creates, and a label survives whatever naming scheme it picks.
mapfile -t WORKERS < <(gcloud compute instances list --project="$PROJECT" \
  --filter="labels.hyper-role=worker" \
  --format='value(name,zone.basename())' 2>/dev/null || true)

CONTROL_EXISTS=0
gcloud compute instances describe "$CONTROL" --project="$PROJECT" --zone="$ZONE" \
  >/dev/null 2>&1 && CONTROL_EXISTS=1

BUCKET_EXISTS=0
gcloud storage buckets describe "gs://${BUCKET}" --project="$PROJECT" \
  >/dev/null 2>&1 && BUCKET_EXISTS=1

echo
echo "About to DELETE:"
if [ "${#WORKERS[@]}" -eq 0 ]; then
  echo "  workers        : (none found with labels.hyper-role=worker)"
else
  for w in "${WORKERS[@]}"; do
    echo "  worker         : ${w%%$'\t'*}  (zone ${w##*$'\t'})"
  done
fi
if [ "$CONTROL_EXISTS" = 1 ]; then
  echo "  control        : ${CONTROL}  (zone ${ZONE})"
else
  echo "  control        : (not found)"
fi
if [ "$DELETE_BUCKET" = 1 ]; then
  if [ "$BUCKET_EXISTS" = 1 ]; then
    echo "  bucket         : gs://${BUCKET}  (AND EVERYTHING IN IT)"
  else
    echo "  bucket         : (not found)"
  fi
else
  echo "  bucket         : gs://${BUCKET} KEPT (set DELETE_BUCKET=1 to remove)"
fi
echo

if [ "${#WORKERS[@]}" -eq 0 ] && [ "$CONTROL_EXISTS" = 0 ] \
   && { [ "$DELETE_BUCKET" != 1 ] || [ "$BUCKET_EXISTS" = 0 ]; }; then
  say "nothing to delete."
  exit 0
fi

if [ "$FORCE" != 1 ]; then
  read -r -p "Delete all of the above? [y/N] " reply
  case "$reply" in
    y|Y|yes|YES) : ;;
    *) say "aborted, nothing deleted."; exit 1 ;;
  esac
fi

for w in "${WORKERS[@]}"; do
  name="${w%%$'\t'*}"
  wzone="${w##*$'\t'}"
  say "deleting worker ${name} (${wzone})"
  gcloud compute instances delete "$name" --project="$PROJECT" --zone="$wzone" --quiet \
    || warn "failed to delete ${name} -- delete it by hand, it is still billing"
done

if [ "$CONTROL_EXISTS" = 1 ]; then
  say "deleting control ${CONTROL} (${ZONE})"
  gcloud compute instances delete "$CONTROL" --project="$PROJECT" --zone="$ZONE" --quiet \
    || warn "failed to delete ${CONTROL} -- delete it by hand, it is still billing"
fi

if [ "$DELETE_BUCKET" = 1 ] && [ "$BUCKET_EXISTS" = 1 ]; then
  say "deleting gs://${BUCKET} and its contents"
  gcloud storage rm -r "gs://${BUCKET}" --project="$PROJECT" \
    || warn "failed to delete gs://${BUCKET}"
fi

say "verifying nothing is left"
gcloud compute instances list --project="$PROJECT" \
  --filter="labels.hyper-role:*" \
  --format='table(name, zone.basename(), status, labels.hyper-role)' || true
say "teardown complete."
