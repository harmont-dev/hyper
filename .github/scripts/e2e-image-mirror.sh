#!/usr/bin/env bash
# Serve the E2E test image from a local registry mirror so the integration
# suite does not pull it anonymously from public.ecr.aws on every run (shared
# runner IPs hit ECR Public's "toomanyrequests: Data limit exceeded").
#
# The image is kept as an OCI layout in $HYPER_E2E_IMAGE_CACHE (persisted by
# actions/cache) and pulled from upstream only when that cache is cold. It is
# pushed to a local docker-registry, and a registries.conf.d mirror entry makes
# every `docker://<registry>/...` pull try the local copy first. The tests and
# Hyper.Img.OciLoader are unchanged: they still pull the upstream ref, so a
# mirror miss falls through to the real registry instead of failing.
#
# Run after the host is provisioned (skopeo installed), with passwordless sudo.
set -euo pipefail

image="${HYPER_E2E_IMAGE:-public.ecr.aws/docker/library/alpine:3.19}"
cache="${HYPER_E2E_IMAGE_CACHE:?set HYPER_E2E_IMAGE_CACHE to the cached OCI layout dir}"
mirror=127.0.0.1:5000

registry="${image%%/*}"
path="${image#*/}"
tag="${path##*:}"

# --multi-arch all keeps the index: the loader picks the entry for the node's
# architecture, so a single-arch copy would not be a faithful stand-in.
if [[ ! -e "$cache/index.json" ]]; then
  mkdir -p "$cache"
  skopeo copy --multi-arch all --retry-times 3 "docker://$image" "oci:$cache:$tag"
fi

export DEBIAN_FRONTEND=noninteractive
sudo apt-get install -y docker-registry
# The packaged config enables htpasswd auth and listens on every interface;
# replace it with an unauthenticated, loopback-only one.
sudo tee /etc/docker/registry/config.yml >/dev/null <<EOF
version: 0.1
storage:
  filesystem:
    rootdirectory: /var/lib/docker-registry
http:
  addr: $mirror
EOF
sudo systemctl restart docker-registry
for _ in $(seq 1 30); do
  curl -fsS "http://$mirror/v2/" >/dev/null 2>&1 && break
  sleep 1
done

skopeo copy --multi-arch all --dest-tls-verify=false \
  "oci:$cache:$tag" "docker://$mirror/$path"

sudo mkdir -p /etc/containers/registries.conf.d
sudo tee /etc/containers/registries.conf.d/50-hyper-e2e-mirror.conf >/dev/null <<EOF
[[registry]]
prefix = "$registry"
location = "$registry"

[[registry.mirror]]
location = "$mirror"
insecure = true
EOF

echo "mirroring $registry via $mirror (seeded with $image)"
