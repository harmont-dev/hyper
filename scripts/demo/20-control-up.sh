#!/usr/bin/env bash
# Create the always-on hyper-control VM: Postgres (docker) + the Hyper release
# running with role = "client", plus the gcloud CLI it shells out to in order to
# create workers.
#
# A client node needs NO KVM, NO Firecracker, NO dm-thin, NO nftables -- that is
# the entire point of the client role, and why this VM can be a cheap
# e2-standard-2 with no nested virtualization.
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

need gcloud
need curl

CONTROL_MACHINE_TYPE="${CONTROL_MACHINE_TYPE:-e2-standard-2}"

say "checking the release tarball is public before we boot anything"
curl -fsI --max-time 20 "$RELEASE_URL" >/dev/null 2>&1 \
  || die "$RELEASE_URL is not fetchable. Run scripts/demo/10-publish-release.sh first."

if gcloud compute instances describe "$CONTROL" --project="$PROJECT" --zone="$ZONE" \
     >/dev/null 2>&1; then
  die "instance ${CONTROL} already exists in ${ZONE}. Tear it down with scripts/demo/99-down.sh first."
fi

say "checking the default compute service account can create instances"
# The control node creates workers by shelling out to gcloud AS ITSELF, using
# the VM's attached service account. If that SA cannot create instances, every
# scale-up fails with a 403 that only shows up in the control node's journal.
# This is a WARNING, not a hard stop: the binding may be granted at the folder
# or org level, or through a custom role, neither of which shows up here.
PROJECT_NUM="$(gcloud projects describe "$PROJECT" --format='get(projectNumber)' 2>/dev/null || true)"
SA="${PROJECT_NUM}-compute@developer.gserviceaccount.com"
if [ -n "$PROJECT_NUM" ]; then
  ROLES="$(gcloud projects get-iam-policy "$PROJECT" \
    --flatten='bindings[].members' \
    --filter="bindings.members:serviceAccount:${SA}" \
    --format='value(bindings.role)' 2>/dev/null || true)"
  case "$ROLES" in
    *compute.instanceAdmin*|*compute.admin*|*roles/editor*|*roles/owner*) : ;;
    *)
      warn "service account ${SA} does not appear to hold"
      warn "roles/compute.instanceAdmin.v1 (or compute.admin/editor/owner) on ${PROJECT}."
      warn "Worker provisioning WILL fail with a 403 unless it is granted elsewhere. Fix with:"
      warn "  gcloud projects add-iam-policy-binding ${PROJECT} \\"
      warn "    --member=serviceAccount:${SA} --role=roles/compute.instanceAdmin.v1"
      warn "  gcloud projects add-iam-policy-binding ${PROJECT} \\"
      warn "    --member=serviceAccount:${SA} --role=roles/iam.serviceAccountUser"
      ;;
  esac
else
  warn "could not read the project number; skipping the service-account permission check"
fi

STARTUP="$(mktemp)"
trap 'rm -f "$STARTUP"' EXIT

# Header: the values the demo scripts resolved, baked in as shell constants.
# The body below is a quoted heredoc so nothing in it is expanded locally.
cat > "$STARTUP" <<EOF
#!/usr/bin/env bash
RELEASE_URL="${RELEASE_URL}"
COOKIE="${COOKIE}"
PROJECT="${PROJECT}"
ZONE="${ZONE}"
MIN_NODES="${MIN_NODES}"
MAX_NODES="${MAX_NODES}"
WORKER_MACHINE_TYPE="${WORKER_MACHINE_TYPE}"
EOF

cat >> "$STARTUP" <<'EOS'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
exec > >(tee -a /var/log/hyper-bootstrap.log | tee /dev/console) 2>&1
log() { printf '\033[1;34m==> [hyper-control]\033[0m %s\n' "$*"; }

# This VM's own internal (VPC) IP. Everything -- the BEAM node name, the
# Postgres URL handed to workers -- is addressed on the internal network.
IP="$(curl -fsS -H 'Metadata-Flavor: Google' \
  http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip)"
[ -n "$IP" ] || { echo "ERROR: could not read internal IP from metadata" >&2; exit 1; }
log "control node internal IP: ${IP}"

log "installing base packages + docker"
apt-get update
apt-get install -y ca-certificates curl gnupg docker.io postgresql-client

log "starting postgres:16"
# Published on 0.0.0.0:5432 so workers elsewhere in the VPC can reach it.
# NOTE: this is reachable ONLY from inside the VPC -- the instance has no
# firewall rule opening 5432 to the internet, and this demo deliberately never
# creates one. The default VPC's built-in "default-allow-internal" rule is what
# lets worker VMs connect; nothing outside the VPC can.
docker rm -f hyper-pg >/dev/null 2>&1 || true
docker run -d --name hyper-pg --restart=always \
  -e POSTGRES_USER=hyper -e POSTGRES_PASSWORD=hyper -e POSTGRES_DB=hyper \
  -p 0.0.0.0:5432:5432 postgres:16

log "waiting for postgres to accept connections"
for _ in $(seq 1 60); do
  docker exec hyper-pg pg_isready -U hyper -d hyper >/dev/null 2>&1 && break
  sleep 2
done
docker exec hyper-pg pg_isready -U hyper -d hyper \
  || { echo "ERROR: postgres never became ready" >&2; exit 1; }

log "installing the gcloud CLI"
# Load-bearing: the CLIENT provisions workers by shelling out to gcloud. The
# Ubuntu cloud image does not ship it.
if ! command -v gcloud >/dev/null 2>&1; then
  curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
    > /etc/apt/sources.list.d/google-cloud-sdk.list
  apt-get update
  apt-get install -y google-cloud-cli
fi
command -v gcloud >/dev/null 2>&1 \
  || { echo "ERROR: gcloud install failed; the autoscaler cannot create workers" >&2; exit 1; }

log "creating system user 'hyper'"
if ! id -u hyper >/dev/null 2>&1; then
  useradd --system --shell /usr/sbin/nologin --home-dir /srv/hyper hyper
fi
# layers/ must pre-exist: boot validation checks for it.
mkdir -p /srv/hyper/layers
chown -R hyper:hyper /srv/hyper

log "downloading + extracting the release into /opt/hyper"
mkdir -p /opt/hyper
curl -fsSL "$RELEASE_URL" | tar -xz -C /opt/hyper
[ -x /opt/hyper/bin/hyper ] \
  || { echo "ERROR: /opt/hyper/bin/hyper missing after extract" >&2; exit 1; }

log "installing bundled suidhelper setuid-root"
# A client boots no VMs, but boot-time identity verification still stats the
# helper, so install it exactly as a worker would.
install -o root -g root -m 4755 \
  /opt/hyper/bin/hyper-suidhelper /usr/local/bin/hyper-suidhelper

log "writing /etc/hyper/config.toml (role = client)"
mkdir -p /etc/hyper
cat > /etc/hyper/config.toml <<TOML
role = "client"
work_dir = "/srv/hyper"

[grpc]
enabled = true
port = 50051

[autoscale]
enabled = true
provider = "gcp"
min_nodes = ${MIN_NODES}
max_nodes = ${MAX_NODES}
reconcile_interval_ms = 20000
provision_timeout_ms = 900000

[autoscale.gcp]
project = "${PROJECT}"
zone = "${ZONE}"
machine_type = "${WORKER_MACHINE_TYPE}"
image_family = "ubuntu-2404-lts-amd64"
image_project = "ubuntu-os-cloud"
hostname_prefix = "hyper-worker"

[autoscale.bootstrap]
release_url = "${RELEASE_URL}"
pg_url = "postgres://hyper:hyper@${IP}:5432/hyper"
cookie = "${COOKIE}"
resolver = "8.8.8.8"
TOML
# Must be root-owned and not group/world writable or Hyper refuses to boot.
chown root:root /etc/hyper/config.toml
chmod 0644 /etc/hyper/config.toml

log "writing /etc/hyper/config.exs"
cat > /etc/hyper/config.exs <<EXS
import Config

config :hyper, Hyper.Img.Db.Repo,
  url: "postgres://hyper:hyper@${IP}:5432/hyper",
  pool_size: 10

config :hyper, Hyper.Cfg.Cluster,
  topologies: [
    hyper: [
      strategy: Hyper.Cluster.Strategy.Postgres,
      config: [poll_interval: 5000, node_ttl: 15000]
    ]
  ]
EXS
chown root:root /etc/hyper/config.exs
chmod 0644 /etc/hyper/config.exs

log "writing /etc/hyper/env"
cat > /etc/hyper/env <<ENV
RELEASE_DISTRIBUTION=name
RELEASE_NODE=hyper@${IP}
RELEASE_COOKIE=${COOKIE}
HYPER_CONFIG=/etc/hyper/config.exs
ENV
chown root:hyper /etc/hyper/env
# Contains the distribution cookie -- keep it out of world read.
chmod 0640 /etc/hyper/env

log "running migrations once, before the service starts"
HYPER_CONFIG=/etc/hyper/config.exs RELEASE_COOKIE="$COOKIE" \
  /opt/hyper/bin/hyper eval "Hyper.Release.migrate()"

log "installing + starting hyper.service"
cat > /etc/systemd/system/hyper.service <<'UNIT'
[Unit]
Description=Hyper control node (client role + autoscaler)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=hyper
Group=hyper
EnvironmentFile=/etc/hyper/env
ExecStart=/opt/hyper/bin/hyper start
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now hyper

log "control bootstrap complete -- node hyper@${IP}"
EOS

say "creating ${CONTROL} (${CONTROL_MACHINE_TYPE}, ubuntu-2404-lts-amd64, ${ZONE})"
gcloud compute instances create "$CONTROL" \
  --project="$PROJECT" \
  --zone="$ZONE" \
  --machine-type="$CONTROL_MACHINE_TYPE" \
  --image-family=ubuntu-2404-lts-amd64 \
  --image-project=ubuntu-os-cloud \
  --boot-disk-size=50GB \
  --boot-disk-type=pd-balanced \
  --network=default \
  --labels=hyper-role=control \
  --scopes=https://www.googleapis.com/auth/cloud-platform \
  --metadata-from-file=startup-script="$STARTUP"

IP="$(control_internal_ip)"
say "control VM created. internal IP: ${IP}"
cat <<INFO

  Postgres  : postgres://hyper:hyper@${IP}:5432/hyper   (VPC-internal only)
  BEAM node : hyper@${IP}
  Bootstrap : ~2-3 minutes (docker + gcloud CLI install dominate)

  Tail the bootstrap:

    gcloud compute ssh ${CONTROL} --zone=${ZONE} --command="sudo journalctl -u hyper -f"

  Or the raw startup-script log:

    gcloud compute ssh ${CONTROL} --zone=${ZONE} --command="sudo tail -f /var/log/hyper-bootstrap.log"

  Then: scripts/demo/30-watch.sh

INFO
