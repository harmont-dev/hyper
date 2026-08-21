# Shared env + helpers for the scripts/demo/* GCP demo scripts.
# Sourced, never executed.

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DEMO_DIR/../.." && pwd)"

if [ -f "$DEMO_DIR/demo.env" ]; then
  # shellcheck disable=SC1091
  set -a; . "$DEMO_DIR/demo.env"; set +a
fi

PROJECT="${PROJECT:-$(gcloud config get-value project 2>/dev/null)}"
ZONE="${ZONE:-us-central1-a}"
CONTROL="${CONTROL:-hyper-control}"
COOKIE="${COOKIE:-hyper-demo-cookie}"
MIN_NODES="${MIN_NODES:-1}"
MAX_NODES="${MAX_NODES:-3}"
WORKER_MACHINE_TYPE="${WORKER_MACHINE_TYPE:-n2-standard-4}"
BUCKET="${BUCKET:-hyper-demo-release-${PROJECT}}"
RELEASE_URL="${RELEASE_URL:-https://storage.googleapis.com/${BUCKET}/hyper.tar.gz}"

if [ -z "$PROJECT" ]; then
  echo "ERROR: PROJECT is unset and \`gcloud config get-value project\` is empty." >&2
  exit 1
fi

say()  { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!!  %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "$1 is not on PATH"; }

control_internal_ip() {
  gcloud compute instances describe "$CONTROL" \
    --project="$PROJECT" --zone="$ZONE" \
    --format='get(networkInterfaces[0].networkIP)' 2>/dev/null
}
