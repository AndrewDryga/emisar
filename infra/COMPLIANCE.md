# infra — SOC 2 Type II control mapping

Scope: the emisar-on-GCP infrastructure in this module (compute, database,
network, TLS, secrets, DNS, monitoring). It is **prepared, not applied**.

**Honest framing.** SOC 2 Type II is an *organizational* attestation that controls
operated effectively over a period — auditors examine policies, people, and
evidence, not just code. No repo "passes SOC 2". What this module does is implement
the **technical controls** a SOC 2 auditor expects of a cloud platform and produce
**evidence** (reviewed IaC, private-by-default networking, audit logging, backups,
monitoring). The table is honest about what's enforced in code (✅), what's a
provider/console setting you must configure (⚙️), and what's an org-level control
outside this repo (📋).

## Production-readiness / control checklist

| Control | Status | Where / evidence |
|---|---|---|
| No public database surface | ✅ | Cloud SQL private IP only (`db.tf`, VPC peering) |
| Database HA (failover) | ✅ | `availability_type = "REGIONAL"` |
| Database backups + PITR | ✅ | automated backups, `point_in_time_recovery_enabled`, 30 retained |
| Database deletion protection | ✅ | `deletion_protection` + Terraform `prevent_destroy` |
| Encryption in transit (edge) | ✅ | HTTPS LB, `RESTRICTED` SSL policy (TLS 1.2+), HTTP→HTTPS redirect |
| Encryption in transit (DB) | ✅ | Cloud SQL `ssl_mode = ENCRYPTED_ONLY` + `DATABASE_SSL=1` |
| Encryption at rest | ⚙️ | Google-managed by default; CMEK is a one-field hardening (Open items) |
| No public compute IPs | ✅ | instances have no external IP; egress via Cloud NAT |
| SSH via IAP + OS Login only | ✅ | `iap_ssh` firewall (35.235.240.0/20), `enable-oslogin`, no 0.0.0.0/0 |
| Host integrity | ✅ | Shielded VM (secure boot + vTPM + integrity monitoring) |
| Least-privilege service account | ✅ | dedicated SA, scoped roles (`iam.tf`), no Owner/Editor |
| Secret management | ✅ | Secret Manager, per-secret accessor; values out-of-band |
| Private image + vuln scanning | ✅ | Artifact Registry (Container Analysis), not public GHCR |
| Cloud Audit Logs (admin + data) | ✅ | `google_project_iam_audit_config` ADMIN_READ/DATA_READ/DATA_WRITE |
| Network flow logs | ✅ | subnet `log_config` + LB request logging |
| Availability: multi-node app | ✅ | regional MIG (2+), auto-healing, GCE clustering (`Emisar.Cluster.GCE`) |
| Monitoring & alerting | ✅ | uptime check + DB CPU/disk + unreachable → email channel |
| DNS integrity | ✅ | DNSSEC (ECDSA), CAA; email auth (SPF/DKIM/DMARC/TLS-RPT/MTA-STS) |
| Change management gate | ✅ | infra CI (fmt/validate/tflint) + PR review + human `terraform apply` |
| Reproducible infra (IaC) | ✅ | whole stack; `git log` is the change record |
| State security | ✅ | GCS `emisar-tfstate` — UBLA + public-access-prevention + versioned |

## SOC 2 Trust Services Criteria — how the platform maps

- **CC6 Logical & physical access** — dedicated least-privilege SA (no Owner/Editor;
  per-secret accessor, `compute.viewer`/`cloudsql.client`/`artifactregistry.reader`
  only). No public compute IPs; SSH exclusively through IAP + OS Login. The database
  has no public IP. Human GCP access + MFA is ⚙️/📋.
- **CC6.1 / CC6.7 Data at rest & in transit** — TLS 1.2+ at the edge (managed cert,
  RESTRICTED policy) and required to the database; at rest via Google-managed keys
  (CMEK optional). **DNSSEC** + **CAA** make DNS answers tamper-evident and constrain
  cert issuance; email is authenticated end-to-end (SPF + two DKIM keys + DMARC) —
  an account-takeover-phishing control for a magic-link product.
- **CC7 System operations / monitoring** — Cloud Audit Logs record every admin and
  data-access action; VPC flow logs + LB request logs give network/edge forensics;
  the uptime check + alert policies detect outages and DB pressure. DMARC/TLS-RPT/CAA
  reporting turn email/cert misuse into signals.
- **CC8 Change management** — every change is IaC through a PR that must pass the
  infra CI gate (fmt/validate/tflint, no creds), is human-reviewed, then applied by
  an authorized operator; the versioned GCS state records each apply. No console
  edits (they'd drift from and be overwritten by the code).
- **A1 Availability** — a regional MIG (≥2 nodes, auto-healing, rolling updates) with
  GCE clustering behind an anycast HTTPS LB; **Cloud SQL regional HA** (synchronous
  standby + automatic failover). DR: automated backups + PITR (RPO minutes) and the
  whole platform as code (re-apply rebuilds it).
- **C1 Confidentiality** — the database is private-IP only; secrets live in Secret
  Manager (per-secret least-priv), never in code; the image registry is private.
- **PI Processing integrity** — DB migrations run under Ecto's advisory lock (one
  runner, others wait); the health check gates traffic so only migrated, healthy
  nodes serve.

## Access & least privilege (configure in GCP)

- **VM service account** (`emisar-vm`): exactly `logging.logWriter`,
  `monitoring.metricWriter`, `compute.viewer` (cluster discovery),
  `artifactregistry.reader` (image pull), `cloudsql.client`, and per-secret
  `secretAccessor`. No Owner/Editor. It uses the metadata token — no long-lived key.
- **Humans**: grant `roles/dns.admin` / project roles to the infra team only; MFA on
  all GCP accounts; SSH via `gcloud compute ssh --tunnel-through-iap` (no keys on the
  box). The apply identity ideally runs from CI via Workload Identity Federation.
- **State bucket** (`emisar-tfstate`): UBLA + public-access-prevention + versioning;
  access to it IS access to change production — grant `storage.objectAdmin` narrowly.

## Data protection

Encryption in transit is end-to-end (browser→LB TLS, LB→app internal, app→DB
required-SSL). At rest is Google-managed AES-256 everywhere; for key custody, set
`encryption_key_name` on Cloud SQL / the disk / Secret Manager (CMEK — Open items).
The app DB password is generated by Terraform and lands in state; this is accepted
because state is the locked-down, versioned, IAM-controlled `emisar-tfstate` bucket.
Externally-issued secrets (SECRET_KEY_BASE, Paddle/Postmark tokens) are added
out-of-band and never enter state. Stronger: Cloud SQL **IAM auth** (no password)
via the Auth Proxy — Open items.

## Backups & disaster recovery

Cloud SQL: automated daily backups + point-in-time recovery (RPO ≈ minutes), 30
backups retained, regional standby for failover. The platform is code, so recovery
of everything else is `terraform apply`. Worth a periodic restore game-day (restore
to a scratch instance, confirm the app boots against it).

## Audit logging

Admin Activity logs (every mutation) are always-on and retained **400 days** in the
immutable `_Required` bucket. **Data Access** logs (who read secrets / DB admin) are
turned on here (`google_project_iam_audit_config`). Plus VPC flow logs and LB
request logs. For a longer window or SIEM, export to BigQuery / a log bucket.

## Vulnerability management

Artifact Registry runs Container Analysis (CVE scanning) on the image; the portal's
own CI runs `sobelow` (Phoenix SAST) + `mix_audit` (dependency CVEs); Shielded VM
guards host boot integrity. Pin `image_tag` to a digest for reproducible rollouts.

## What is NOT in this module (org-level — flagged, not hidden)

SOC 2 Type II also needs controls no Terraform provides: an infosec policy,
periodic access reviews, onboarding/offboarding, vendor/subprocessor management
(Google, GoDaddy, Postmark, Paddle, BetterUptime), incident-response + BCP/DR
runbooks *with evidence they were tested over the period*, risk assessment, change-
approval records, and security training. This module supplies technical evidence for
CC6/CC7/CC8/A1/C1/PI; the rest is process the organization operates and evidences.

## Open items / hardening

- **CMEK** on Cloud SQL + Secret Manager + disks if key custody is required.
- **Cloud SQL IAM auth** (no password) via the Auth Proxy sidecar in cloud-init.
- **Cloud Armor** WAF + rate-limiting attached to the backend service.
- **Workload Identity Federation** so `terraform apply` runs from CI, not a laptop.
- Wire DMARC/TLS-RPT report inboxes; ramp DMARC → reject and MTA-STS → enforce.
- More alert channels (PagerDuty/Slack) + policies (5xx rate, cert expiry).
