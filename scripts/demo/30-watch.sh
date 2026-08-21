#!/usr/bin/env bash
# The demo's live view. Redraws in place every 5s:
#   1. cluster_nodes as Postgres on the control VM sees it (node, role, age)
#   2. the worker instances GCE currently has, with STATUS
#   3. the tail of the autoscaler's own log on the control node
#
# Ctrl-C to stop.
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

need gcloud

INTERVAL="${INTERVAL:-5}"

# updated_at is a naive UTC timestamp; compare against UTC, not the container's
# local now(), or every age comes out shifted by the TZ offset.
SQL="SELECT node, role, round(extract(epoch from (now() at time zone 'utc' - updated_at)))::int AS age_s FROM cluster_nodes ORDER BY role, node;"

# One ssh round-trip per refresh: both control-side reads in a single command.
REMOTE="sudo docker exec hyper-pg psql -U hyper -d hyper -P pager=off -c \"${SQL}\" 2>&1; echo '---JOURNAL---'; sudo journalctl -u hyper -n 400 --no-pager 2>&1 | grep -iE 'autoscale|provision|worker|capacity' | tail -8"

hr() { printf '\033[2m%s\033[0m\n' "------------------------------------------------------------------------"; }

while true; do
  remote_out="$(gcloud compute ssh "$CONTROL" --project="$PROJECT" --zone="$ZONE" \
                  --quiet \
                  --command="$REMOTE" 2>&1 || echo "ssh to ${CONTROL} failed (still booting?)")"

  workers="$(gcloud compute instances list --project="$PROJECT" \
               --filter="labels.hyper-role=worker" \
               --format='table(name, zone.basename(), machineType.basename(), status, networkInterfaces[0].networkIP)' \
               2>&1 || echo "instances list failed")"

  if command -v tput >/dev/null 2>&1; then tput cup 0 0; tput ed; else clear; fi

  printf '\033[1;36m HYPER DEMO \033[0m  project=%s zone=%s  %s\n' \
    "$PROJECT" "$ZONE" "$(date -u '+%H:%M:%SZ')"
  hr
  printf '\033[1mcluster_nodes (postgres on %s)\033[0m\n' "$CONTROL"
  printf '%s\n' "${remote_out%%---JOURNAL---*}"
  hr
  printf '\033[1mworker instances (labels.hyper-role=worker)\033[0m\n'
  if [ "$(printf '%s' "$workers" | wc -l)" -lt 1 ]; then
    printf '  (none yet)\n'
  else
    printf '%s\n' "$workers"
  fi
  hr
  printf '\033[1mautoscaler log tail\033[0m\n'
  case "$remote_out" in
    *---JOURNAL---*) printf '%s\n' "${remote_out#*---JOURNAL---}" ;;
    *)               printf '  (unavailable)\n' ;;
  esac
  hr
  printf '\033[2mrefresh every %ss -- Ctrl-C to stop\033[0m\n' "$INTERVAL"

  sleep "$INTERVAL"
done
