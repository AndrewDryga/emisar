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
 DNSSEC-signed)  └─ :80 → :443 redirect ┘                               container, 1+ nodes)
                                                                             │
   Secret Manager (runtime secrets, from TFC vars) ── public GHCR (image)   │
                                                                             ▼
                          dedicated VPC ── Cloud NAT ── Cloud SQL Postgres (private IP,
                          (flow logs)      (egress)     regional HA, PITR backups)
```

> **Applied 2026-07-11 — NOT LIVE.** The stack exists in GCP, but emisar still
> serves from Fly.io: the live nameservers are GoDaddy's, so the zone edits here
> (apex A/AAAA → the GCP LB, CAA + `pki.goog`) are invisible until NS delegation.
> The move to GCP is the **Cutover runbook** below, walked in order — the data
> import and cert pre-provisioning come BEFORE any traffic change. Environment
> sizing (machine type, node count, DB tier/availability) and the alert address
> are Terraform Cloud workspace variables, not committed values.

## What's in it

| Area | Resources | SOC 2 relevance |
|---|---|---|
| Network | dedicated VPC + subnet (flow logs), Cloud Router + NAT, private service access | segmentation; DB/compute private (the only public read is the pack bucket) |
| Compute | regional MIG of Container-Optimized OS running the portal image; Shielded VM; auto-heal + rolling updates against a matching capacity reservation (no surge — a rollout can never fail on zone stockout); `instance_count` 2+ forms one BEAM cluster | availability; host integrity |
| Database | Cloud SQL Postgres 18 (latest major) — private IP, PITR backups, SSL-required, deletion-protected; `db_availability_type = "REGIONAL"` runs a synchronous standby with automatic failover | availability, durability/DR, confidentiality |
| TLS | Certificate Manager managed cert (DNS-auth; apex + www + mta-sts SANs), RESTRICTED SSL policy (TLS 1.2+) | encryption in transit |
| Secrets | TFC workspace variables → Secret Manager versions; per-secret least-priv access; machine secrets generated in-config | secret management |
| Image | public GHCR — prod runs the exact artifact self-hosters pull; pin digests | supply-chain transparency |
| Pack registry | GCS bucket, **public-read** (the one deliberate public surface), object-versioned, create-only publisher SA; serves catalog/suggest/schema + immutable pack tarballs | integrity; supply-chain transparency |
| IAM | dedicated least-priv service account; Data Access audit logging | logical access; audit trail |
| DNS | Cloud DNS zone (DNSSEC ECDSA) + full email posture (SPF/DKIM/DMARC/CAA/TLS-RPT/MTA-STS) | integrity; anti-spoofing |
| Monitoring | uptime check + alert policies (unreachable, LB 5xx ratio, cert renewal failing, MIG below target, NAT exhaustion, DB CPU/memory/disk/txid-wraparound) → email channel | detection |

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
(`emisar-pack-publisher`) holds bucket-scoped **`objectUser`** (objects
create/get/list/delete — no bucket config, no IAM). It can't be create-only:
republishing the mutable pointers (`catalog.json`, `suggest.json`) *replaces* the
live object, and GCS requires `storage.objects.delete` for an overwrite even with
versioning on — `objectCreator` would 403 the second publish. Every replaced
generation stays fetchable. The canonical customer-facing output is
`pack_registry_base_url` (`https://registry.emisar.dev`); the direct GCS endpoint
is exposed separately as `pack_registry_backing_url` for storage administration
and cutover diagnostics. Recover an accidentally-overwritten mutable object (the
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

## Environment sizing

Machine type, MIG size, database tier/availability, and the alert address are
**Terraform Cloud workspace variables** (org `Dryga` / workspace `emisar`), not
committed values — the repo's defaults are a reference configuration. Adjust an
environment in the workspace, then apply; the dials are `machine_type`,
`instance_count`, `db_tier`, `db_availability_type`, `db_disk_size_gb`, and
`alert_email`.

## Cutover runbook (Fly → GCP, in this order)

The order is the point: the cert can't provision and the data isn't there until
you make both happen — flipping DNS first means an outage on an empty database.

```bash
# 0. Once: bootstrap APIs Terraform can't enable itself. TFC (org Dryga →
#    workspace emisar) already holds WIF creds + the sensitive secret vars;
#    SECRET_KEY_BASE and the DB password are generated by the apply.
gcloud services enable serviceusage.googleapis.com cloudresourcemanager.googleapis.com --project=emisar

# 1. Merge through the required `Required - CI` check. CI publishes the exact image it
#    smoke-tested, uploads this commit's infra configuration, and creates an
#    HCP Terraform plan using the immutable digest. FIRST publish only: GHCR
#    creates the package PRIVATE — flip it to Public or instance pulls 403.

# 2. Review the complete saved plan in HCP Terraform, then click
#    `Confirm & Apply` there. CI has no automated apply step. The run blocks
#    until the MIG serves /healthz.

# 3. Import production data — the portal serves an EMPTY schema until this runs.
#    Stop writers on both sides first: fly scale count 0 (freezes prod), and
#    gcloud compute instance-groups managed resize emisar --region=us-central1 --size=0
#    (recurrent jobs on the GCP side would fight the import).
#    Dump through the Fly Managed Postgres tunnel (`fly mpg proxy`, then pg_dump
#    against the local port it prints):
pg_dump --format=custom --no-owner --no-privileges "$FLY_DATABASE_URL" > emisar.dump
#    Restore from inside the VPC (the DB has no public IP): IAP-SSH into a MIG VM
#    and pg_restore --clean --if-exists there (boot already created the schema),
#    or plain-SQL dump → gcloud storage cp → gcloud sql import sql --user=emisar.
#    Then resize the MIG back to var.instance_count.
#    Optional (keeps operator sessions alive across the cutover): store Fly's
#    SECRET_KEY_BASE as the newest version — instances read versions/latest:
printf '%s' "$FLY_SECRET_KEY_BASE" | gcloud secrets versions add emisar-secret-key-base --data-file=-

# 4. Pre-provision the cert while GoDaddy still serves the live DNS — the cert's
#    DNS-auth records exist only in the (not yet authoritative) Cloud DNS zone,
#    and the live CAA doesn't allow Google's CA yet:
terraform state show 'google_certificate_manager_dns_authorization.emisar'      # + .www / .mta_sts
#    → at GoDaddy add those three _acme-challenge CNAMEs AND a CAA record:
#      0 issue "pki.goog"   (keep the letsencrypt.org one — Fly renews with it)
#    Wait for the cert to go ACTIVE, then prove the stack end-to-end:
curl --resolve emisar.dev:443:$(terraform output -raw lb_ipv4) https://emisar.dev/healthz

# 5. Converge traffic at GoDaddy FIRST. NS propagation takes up to 48 h — two
#    providers answering different IPs means writes split across two databases.
#    Lower the A/AAAA TTLs, then point A → lb_ipv4 and AAAA → lb_ipv6 at GoDaddy.
#    Both DNS providers now answer the same IPs; watch runners reconnect and
#    runs flow on GCP before touching NS.

# 6. Delegate: set NS at GoDaddy to `terraform output nameservers` — now a
#    zero-traffic change. scripts/verify-cutover.sh <new-ns> compares the zone
#    against live records first.

# 7. LAST, after NS resolves everywhere: publish the DNSSEC DS at the registrar
#    (`terraform output dnssec_ds_record`) — a DS ahead of working delegation
#    takes the domain offline. Keep Fly running until traffic drains, then
#    decommission it (MAILER_FROM_EMAIL parity is already var.mailer_from_email).
```

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

CI (the `infra` job in `.github/workflows/ci.yml`) runs the same with no cloud credentials.
State and the sensitive secret variables live in the Terraform Cloud workspace
(org `Dryga` / project `emisar`) — encrypted at rest, RBAC-gated, audit-logged;
treat workspace membership as production access.
