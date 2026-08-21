#!/usr/bin/env bash
# Trigger a scale-up so the demo has a story.
#
# Two modes, and the difference matters -- do not conflate them:
#
#   MODE=vm  (honest, preferred)
#     Submits real Hyper.create_vm/1 requests against IMG_ID until the cluster
#     scheduler answers {:error, :no_capacity}. That is the production path:
#     Hyper.create_vm/1 sees a capacity error and calls
#     Hyper.Autoscale.request_capacity/0 itself (lib/hyper.ex:38-39). This
#     proves the whole chain -- placement, capacity refusal, reactive burst.
#     Requires an image already in the DB; export IMG_ID=<hyper image id>.
#
#   MODE=capacity  (FALLBACK, the default when IMG_ID is unset)
#     Calls Hyper.Autoscale.request_capacity/0 directly over `bin/hyper rpc` on
#     the control node. This proves the autoscaler + the GCP provider + worker
#     bootstrap + cluster join all work. It does NOT prove that a real placement
#     failure would have reached the autoscaler -- it skips the scheduler
#     entirely and pokes the autoscaler by hand. Say so out loud in the demo.
#
# Neither mode prints a result the system did not produce: everything below is
# the node's own output.
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

need gcloud

IMG_ID="${IMG_ID:-}"
COUNT="${COUNT:-10}"
MODE="${MODE:-$([ -n "$IMG_ID" ] && echo vm || echo capacity)}"

run_on_control() {
  gcloud compute ssh "$CONTROL" --project="$PROJECT" --zone="$ZONE" --quiet \
    --command="sudo -u hyper env \$(sudo cat /etc/hyper/env | tr '\n' ' ') /opt/hyper/bin/hyper rpc '$1'"
}

case "$MODE" in
  vm)
    [ -n "$IMG_ID" ] || die "MODE=vm needs IMG_ID=<image id> exported"
    say "submitting up to ${COUNT} VM create requests for image ${IMG_ID}"
    say "watching for {:error, :no_capacity} -- that is what fires the autoscaler"
    # The loop lives inside a single rpc call: one ssh round-trip, and the
    # requests are issued back-to-back so the cluster actually fills up.
    ELIXIR="spec = %Hyper.Vm.Spec{img_id: \"${IMG_ID}\"}; Enum.each(1..${COUNT}, fn i -> IO.inspect({i, Hyper.create_vm(spec)}) end)"
    run_on_control "$ELIXIR"
    ;;
  capacity)
    warn "FALLBACK MODE: poking Hyper.Autoscale.request_capacity/0 directly."
    warn "This does NOT exercise the scheduler's :no_capacity path. Set IMG_ID=... for MODE=vm."
    say "calling Hyper.Autoscale.request_capacity/0 on ${CONTROL}"
    run_on_control 'IO.inspect(Hyper.Autoscale.request_capacity())'
    ;;
  *)
    die "unknown MODE=${MODE} (expected 'vm' or 'capacity')"
    ;;
esac

say "request submitted. Watch it land with scripts/demo/30-watch.sh"
say "a new worker takes ~4-6 minutes to boot, bootstrap and join the cluster."
