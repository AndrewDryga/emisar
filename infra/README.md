# infra — emisar on GCP

Terraform for running the emisar control plane on **Google Cloud**, built to a
**SOC 2 Type II** posture. Adapted from `../onlytty/infra` (same LB + MIG + managed
cert + Secret Manager shape) and extended for emisar: a **Cloud SQL** database,
emisar's full secret set, a **private Artifact Registry**, GCE **clustering**, and
the SOC 2 control layer (audit logs, private networking, backups/DR, monitoring).

```
                 ┌─ IPv4/IPv6 anycast ─┐
DNS A/AAAA ──────┤  HTTPS LB (TLS via   ├─► backend (HTTP /healthz) ─► regional MIG
(Cloud DNS,      │  Certificate Manager)│                              (COS, portal
 DNSSEC-signed)  └─ :80 → :443 redirect ┘                               container, 2+ nodes)
                                                                             │
   Secret Manager (all runtime secrets) ── Artifact Registry (private image)│
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
| Network | dedicated VPC + subnet (flow logs), Cloud Router + NAT, private service access | segmentation; no public data-store surface |
| Compute | regional MIG of Container-Optimized OS running the portal image; Shielded VM; auto-heal + rolling updates | availability; host integrity |
| Database | Cloud SQL Postgres 16 — private IP, regional HA, PITR backups, SSL-required, deletion-protected | availability, durability/DR, confidentiality |
| TLS | Certificate Manager managed cert (DNS-auth), RESTRICTED SSL policy (TLS 1.2+) | encryption in transit |
| Secrets | Secret Manager for every runtime secret; per-secret least-priv access | secret management |
| Registry | private Artifact Registry (Container Analysis scanning) | supply chain / vuln mgmt |
| IAM | dedicated least-priv service account; Data Access audit logging | logical access; audit trail |
| DNS | Cloud DNS zone (DNSSEC ECDSA) + full email posture (SPF/DKIM/DMARC/CAA/TLS-RPT/MTA-STS) | integrity; anti-spoofing |
| Monitoring | uptime check + alert policies (DB CPU/disk, unreachable) → email channel | detection |

`COMPLIANCE.md` maps each of these to the SOC 2 Trust Services Criteria and is
honest about what's enforced in code vs. configured vs. org-owned.

## Files

`network.tf` · `compute.tf` · `db.tf` · `lb.tf` · `secrets.tf` · `iam.tf`
(SA + audit) · `monitoring.tf` · `dns.tf` · `main.tf` (provider + APIs + registry)
· `variables.tf` · `outputs.tf` · `versions.tf` · `templates/cloud-init.yaml` ·
`scripts/verify-cutover.sh`.

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

# 1. Build + push the portal image to the (Terraform-created) Artifact Registry:
#    terraform apply -target=google_artifact_registry_repository.emisar   # first, to create the repo
gcloud auth configure-docker <region>-docker.pkg.dev
docker build -t <region>-docker.pkg.dev/<project>/emisar/emisar:<tag> portal && docker push …

# 2. Add the secret VALUES (never in state; DATABASE_URL is filled by apply):
mix phx.gen.secret | gcloud secrets versions add emisar-secret-key-base --data-file=- --project=<project>
#    then emisar-paddle-api-key / -webhook-secret / -client-token (or set disable_billing=true),
#    and optionally emisar-postmark-* / -sentry-dsn / -mixpanel-token.

# 3. Full apply (VPC, Cloud SQL, MIG, LB, cert, DNS zone). Blocks until the MIG is healthy.
terraform apply

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
State lives in the versioned, private `emisar-tfstate` GCS bucket; the generated DB
password is in state (mitigated by the locked-down bucket) while externally-issued
secrets stay out-of-band — see `COMPLIANCE.md`.
