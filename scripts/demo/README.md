# Hyper GCP demo

Stands the whole demo up on GCP: one always-on control node running Postgres and
Hyper in the `client` role, and worker VMs that `Hyper.Autoscale` creates on
demand through the `gcloud` CLI. Everything lives in one project, one zone, the
default VPC, and nodes address each other by **internal IP** (the default VPC's
`default-allow-internal` rule already permits EPMD/4369 and BEAM distribution,
so there is no firewall work to do).

## Run these in order

| # | Script | What it does |
|---|--------|--------------|
| 1 | `10-publish-release.sh` | Builds `MIX_ENV=prod mix release` and publishes `_build/prod/hyper-0.1.0.tar.gz` to GCS as a public object, then verifies the URL with `curl -fsI`. |
| 2 | `20-control-up.sh` | Creates `hyper-control`: Postgres 16 in docker, the release in `/opt/hyper`, `role = "client"` + the `[autoscale]` tables, the gcloud CLI, migrations, `hyper.service`. |
| 3 | `30-watch.sh` | The live view. Redraws every 5s: `cluster_nodes`, worker instances, autoscaler log tail. |
| 4 | `40-drive-load.sh` | Triggers a scale-up. |
| 5 | `99-down.sh` | Deletes every worker, the control VM, optionally the bucket. **Run this or you keep paying.** |

## Configuration

All scripts source `demo.env` if it exists; anything already exported in your
shell wins over it.

| Var | Default | Meaning |
|-----|---------|---------|
| `PROJECT` | `gcloud config get-value project` | GCP project |
| `ZONE` | `us-central1-a` | zone for control + workers |
| `BUCKET` | `hyper-demo-release-$PROJECT` | GCS bucket for the release tarball |
| `CONTROL` | `hyper-control` | control VM name |
| `COOKIE` | `hyper-demo-cookie` | BEAM distribution cookie |
| `MIN_NODES` / `MAX_NODES` | `1` / `3` | autoscaler bounds |
| `WORKER_MACHINE_TYPE` | `n2-standard-4` | worker size (must support nested virt) |
| `CONTROL_MACHINE_TYPE` | `e2-standard-2` | control size (no KVM needed) |
| `IMG_ID` | *(unset)* | `40-drive-load.sh`: image to place, enables the honest `MODE=vm` path |
| `FORCE` / `DELETE_BUCKET` | `0` / `0` | `99-down.sh`: skip prompt / also delete the bucket |

## Expected timeline

- `10-publish-release.sh` — 1-3 min (the release build dominates; the ~42 MB
  upload is quick).
- `20-control-up.sh` — the instance appears in seconds; **bootstrap takes ~2-3
  min** (docker + gcloud CLI install). Hyper is up when
  `journalctl -u hyper -f` stops moving and `cluster_nodes` has one row.
- First worker joining — **~4-6 min after** the control node is healthy: GCE
  create, Ubuntu boot, the startup script's apt install + Firecracker download,
  then the Postgres-strategy poll (5 s) and the BEAM mesh converging.

So: from a cold `10-` to a two-node cluster, budget about 10 minutes.

## If it did not work, look here

**1. The GCS object is not public.** By far the most likely failure. The worker
startup script fetches the tarball with plain `curl` and no credentials; a 403
leaves you with a VM that boots and then silently never joins. `10-` verifies
the URL with `curl -fsI` on purpose so this surfaces at publish time. If it
fails there: uniform bucket-level access blocks per-object ACLs, so the fix is
the bucket IAM binding (`roles/storage.objectViewer` for `allUsers`), not
`gsutil acl`. Also check for an org policy
`constraints/storage.publicAccessPrevention`, which forbids it outright.

```sh
curl -fsI https://storage.googleapis.com/$BUCKET/hyper.tar.gz
gcloud storage buckets get-iam-policy gs://$BUCKET
```

**2. The control node's service account cannot create instances.** The client
provisions workers by shelling out to `gcloud` **as itself**, using the VM's
attached service account. Without `roles/compute.instanceAdmin.v1` every
scale-up dies with a 403 that only appears in the control node's journal.
`20-` warns about this before creating the VM, but a folder/org-level or custom
role will not show up in that check.

```sh
gcloud projects add-iam-policy-binding $PROJECT \
  --member=serviceAccount:PROJECT_NUMBER-compute@developer.gserviceaccount.com \
  --role=roles/compute.instanceAdmin.v1
gcloud projects add-iam-policy-binding $PROJECT \
  --member=serviceAccount:PROJECT_NUMBER-compute@developer.gserviceaccount.com \
  --role=roles/iam.serviceAccountUser
```

**3. Nested virtualization is not available.** Workers run Firecracker, which
needs `/dev/kvm`, which on GCE needs nested virtualization — available on N2/N1
(Haswell+) but **not** on E2, T2A/Arm, or any machine type on AMD hosts in some
zones. A worker without it boots, bootstraps, joins the cluster, and then fails
the moment it is asked to start a VM.

```sh
gcloud compute ssh hyper-worker-1 --zone=$ZONE --command='ls -l /dev/kvm'
gcloud compute machine-types describe $WORKER_MACHINE_TYPE --zone=$ZONE
```

Keep `--image-family=ubuntu-2404-lts-amd64`: the release is built on Ubuntu
24.04 / glibc 2.39 locally and runs unmodified only on a matching image.
