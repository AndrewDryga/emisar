# infra — emisar on GCP

Terraform for running the emisar control plane on **Google Cloud**, built to a
**SOC 2 Type II** posture. Adapted from `../onlytty/infra` (same LB + MIG + managed
cert + Secret Manager + public-GHCR shape) and extended for emisar: a **Cloud SQL**
database, emisar's full secret set (via Terraform Cloud variables), GCE
**clustering**, and the SOC 2 control layer (audit logs, private networking,
backups/DR, monitoring).

```
                 ┌─ IPv4/IPv6 anycast ─┐
DNS A/AAAA ──────┤  HTTPS LB (TLS via   ├─► backend (HTTP /healthz) ─► regional MIG
(Cloud DNS,      │  Certificate Manager)│                              (COS, portal
 DNSSEC-signed)  └─ :80 → :443 redirect ┘                               container, 2+ nodes)
                                                                             │
   Secret Manager (runtime secrets, from TFC vars) ── public GHCR (image)   │
                                                                             ▼
                          dedicated VPC ── Cloud NAT ── Cloud SQL Postgres (private IP,
                          (flow logs)      (egress)     regional HA, PITR backups)
```

> **This is prepared, not applied.** Per the task that created it, the code is
> ready to `terraform apply` but has not been run. emisar currently serves from
> Fly.io; the previously-applied state in this module is just the Cloud DNS zone.
> Applying this stack is a deliberate **Fly → GCP migration** (the apex A/AAAA move
> from Fly to the GCP LB, the cert becomes Google-managed). Nothing here touches
> the live domain until you apply *and* delegate the nameservers.

## What's in it

| Area | Resources | SOC 2 relevance |
|---|---|---|
| Network | dedicated VPC + subnet (flow logs), Cloud Router + NAT, private service access | segmentation; DB/compute private (the only public read is the pack bucket) |
| Compute | regional MIG of Container-Optimized OS running the portal image; Shielded VM; auto-heal + rolling updates | availability; host integrity |
| Database | Cloud SQL Postgres 18 (latest major) — private IP, regional HA, PITR backups, SSL-required, deletion-protected | availability, durability/DR, confidentiality |
| TLS | Certificate Manager managed cert (DNS-auth; apex + www + mta-sts SANs), RESTRICTED SSL policy (TLS 1.2+) | encryption in transit |
| Secrets | TFC workspace variables → Secret Manager versions; per-secret least-priv access; machine secrets generated in-config | secret management |
| Image | public GHCR — prod runs the exact artifact self-hosters pull; pin digests | supply-chain transparency |
| Pack registry | GCS bucket, **public-read** (the one deliberate public surface), object-versioned, create-only publisher SA; serves catalog/suggest/schema + immutable pack tarballs | integrity; supply-chain transparency |
| IAM | dedicated least-priv service account; Data Access audit logging | logical access; audit trail |
| DNS | Cloud DNS zone (DNSSEC ECDSA) + full email posture (SPF/DKIM/DMARC/CAA/TLS-RPT/MTA-STS) | integrity; anti-spoofing |
| Monitoring | uptime check + alert policies (DB CPU/disk, unreachable) → email channel | detection |

`COMPLIANCE.md` maps each of these to the SOC 2 Trust Services Criteria and is
honest about what's enforced in code vs. configured vs. org-owned.

## Files

`network.tf` · `compute.tf` · `db.tf` · `lb.tf` · `secrets.tf` · `iam.tf`
(SA + audit) · `packs_registry.tf` (public pack bucket + publisher SA) ·
`monitoring.tf` · `dns.tf` · `main.tf` (TFC backend + provider +
APIs) · `variables.tf` · `outputs.tf` · `versions.tf` ·
`templates/cloud-init.yaml` · `scripts/verify-cutover.sh`.

## Pack registry (the one public-read surface)

Everything else here is private by default. `packs_registry.tf` is the deliberate,
documented exception: `emisar pack install <id>` runs **unauthenticated**, so the
published pack artifacts — `catalog.json`, `suggest.json`, the JSON schemas, and
the immutable pack tarballs — live in a **public-read** GCS bucket
(`var.pack_registry_bucket`, default `emisar-pack-registry`). The safety argument:
nothing secret or account-scoped is ever written there (only pack bytes that are
already public source in `packs/` plus their metadata), and install trust doesn't
rest on the transport — snippets pin `--hash sha256:...` and the runner rejects any
tampered tarball. History is preserved by **object versioning** (no lifecycle
delete rule; the bucket is `prevent_destroy`), and the CI publisher SA
(`emisar-pack-publisher`) holds **`objectCreator` only** — it can append new
artifacts but cannot delete or mutate history. Outputs: `pack_registry_bucket` and
`pack_registry_base_url`. Recover an accidentally-overwritten mutable object (the
latest `catalog.json` pointer) from a prior generation:

```bash
gcloud storage ls -a gs://$(terraform output -raw pack_registry_bucket)/v1/catalog.json   # list generations
gcloud storage cp gs://<bucket>/v1/catalog.json#<generation> gs://<bucket>/v1/catalog.json # restore one
```

## Clustering (emisar-specific vs onlytty)

On Fly, emisar clusters via `dns_cluster` (`<app>.internal`). GCP MIGs have no such
DNS name, so on GCP emisar uses **libcluster's GCE strategy** (`Emisar.Cluster.GCE`
+ `…/gce/client.ex`): it lists the MIG's RUNNING instances via the Compute API (by
the `cluster_name=emisar` label) and connects `emisar@<internal-ip>`. It activates
only when `EMISAR_CLUSTER_PROJECT` is set (the instance template sets it) — the Fly
path is untouched. This is what lets `instance_count > 1` form one BEAM cluster so
PubSub/Presence span nodes and runs don't strand in `:sent`.

## Deploy runbook (when you do apply)

```bash
# 0. Bootstrap the base APIs once (Terraform can't enable services without these):
gcloud services enable serviceusage.googleapis.com cloudresourcemanager.googleapis.com --project=<project>

# 1. Terraform Cloud (org Dryga → project emisar → workspace emisar) is ALREADY
#    configured (2026-07-09): WIF dynamic credentials (four TFC_GCP_* env vars →
#    pool terraform-cloud / provider emisar-workspace / SA terraform@emisar.iam,
#    no stored key), the six sensitive secret vars, and project_id. The existing
#    Cloud DNS zone + records are imported into the workspace state. Nothing to
#    paste. SECRET_KEY_BASE and the DB password are generated by the apply.
#    (A new secret later = a sensitive workspace variable; see COMPLIANCE.md.)

# 2. Publish the portal image to PUBLIC GHCR (ghcr.io/andrewdryga/emisar:<tag>) —
#    self-hosters pull the same artifact. Pin container_image to a digest for a
#    reproducible rollout. (The publish workflow is an open item; see COMPLIANCE.md.)

# 3. Full apply (VPC, Cloud SQL, MIG, LB, cert, DNS zone). Blocks until the MIG is healthy.
terraform login && terraform init && terraform apply

# 4. Delegate + finish DNSSEC (see `terraform output next_steps`):
terraform output nameservers          # set at the registrar
terraform output dnssec_ds_record     # add at the registrar LAST, after NS resolves
```

`scripts/verify-cutover.sh <new-ns>` compares the zone against the live records
before you flip nameservers.

## Email posture (DMARC / MTA-STS)

These records are provider-independent and carry over from the DNS work: DMARC
starts at `p=none` and ramps (`var.dmarc_policy`); MTA-STS ships in `mode: testing`
(the portal serves `/.well-known/mta-sts.txt`) and flips to enforce after TLS-RPT
reports are clean. See the record comments in `dns.tf`.

## Validate locally (does not apply)

```bash
terraform fmt -check -recursive
terraform init -backend=false && terraform validate
tflint --init && tflint
```

CI (`.github/workflows/infra-ci.yml`) runs the same with no cloud credentials.
State and the sensitive secret variables live in the Terraform Cloud workspace
(org `Dryga` / project `emisar`) — encrypted at rest, RBAC-gated, audit-logged;
treat workspace membership as production access. See `COMPLIANCE.md`.
