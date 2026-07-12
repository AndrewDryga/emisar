# infra — SOC 2 Type II control mapping

Scope: the emisar-on-GCP infrastructure in this module (compute, database,
network, TLS, secrets, DNS, monitoring). First applied 2026-07-11; not serving
traffic until the README's cutover runbook completes.

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
| Public data surface, scoped + justified | ⚙️ | ONE public-read GCS bucket for pack artifacts (`packs_registry.tf`) — unauthenticated `emisar pack install` requires it; no secret/account data ever written there; `objectViewer` to `allUsers` on objects only |
| Pack artifact integrity + retention | ✅ | object versioning on, no lifecycle delete, `prevent_destroy`; publisher SA bucket-scoped `objectUser` (objects only — replacing the mutable catalog pointer needs `objects.delete`; every replaced generation stays fetchable); install trust is the pinned `--hash`, not the transport |
| Database HA (failover) | ⚙️ | `db_availability_type` (workspace-set): `REGIONAL` = synchronous standby + automatic failover (requires a db-custom tier); `ZONAL` relies on backups + PITR |
| Database backups + PITR | ✅ | automated backups, `point_in_time_recovery_enabled`, 30 retained |
| Database deletion protection | ✅ | `deletion_protection` + Terraform `prevent_destroy` |
| Encryption in transit (edge) | ✅ | HTTPS LB, `RESTRICTED` SSL policy (TLS 1.2+), HTTP→HTTPS redirect |
| Encryption in transit (DB) | ✅ | Cloud SQL `ssl_mode = ENCRYPTED_ONLY` + `DATABASE_SSL=1` |
| Encryption at rest | ⚙️ | Google-managed by default; CMEK is a one-field hardening (Open items) |
| No public compute IPs | ✅ | instances have no external IP; egress via Cloud NAT |
| SSH via IAP + OS Login only | ✅ | `iap_ssh` firewall (35.235.240.0/20), `enable-oslogin`, no 0.0.0.0/0 |
| Host integrity | ✅ | Shielded VM (secure boot + vTPM + integrity monitoring) |
| Least-privilege service account | ✅ | dedicated SA, scoped roles (`iam.tf`), no Owner/Editor |
| Secret management | ✅/⚙️ | TFC workspace vars (sensitive) → Secret Manager; machine secrets generated in-config; per-secret accessor |
| Image supply chain | ⚙️/📋 | public GHCR **by design** — prod runs the artifact self-hosters pull; immutable `sha-<sha>` tags published per build for pinning/rollback; trivy blocks fixable HIGH/CRITICAL at publish (portal-cd.yml) |
| Cloud Audit Logs (admin + data) | ✅ | `google_project_iam_audit_config` ADMIN_READ/DATA_READ/DATA_WRITE |
| Network flow logs | ✅ | subnet `log_config` + LB request logging |
| Availability: multi-node app | ⚙️ | regional MIG, auto-healing, rolling updates; `instance_count` (workspace-set) — 2+ forms the BEAM cluster (`Emisar.Cluster.GCE`), 1 relies on auto-heal replacement |
| Monitoring & alerting | ✅ | uptime check + DB CPU/disk + unreachable → email channel |
| DNS integrity | ✅ | DNSSEC (ECDSA), CAA; email auth (SPF/DKIM/DMARC/TLS-RPT/MTA-STS) |
| Change management gate | ✅ | infra CI (fmt/validate/tflint) + PR review + human `terraform apply` |
| Reproducible infra (IaC) | ✅ | whole stack; `git log` is the change record |
| State + secret custody | ⚙️ | Terraform Cloud (org Dryga / project emisar) — encrypted at rest, workspace RBAC, audit log; **workspace access = prod-secret access** |
| Keyless deploy identities (WIF) | ✅/⚙️ | two, no stored key anywhere: pool `terraform-cloud` / provider `emisar-workspace` pinned to `organization:Dryga:project:emisar:workspace:emisar` → SA `terraform@emisar.iam` (applies); pool `github-actions` pinned to this repository → SA `emisar-deployer` with a custom MIG-rolling-replace-only role (deploy.tf, CD) |

## SOC 2 Trust Services Criteria — how the platform maps

- **CC6 Logical & physical access** — dedicated least-privilege SA (no Owner/Editor;
  per-secret accessor, `compute.viewer`/`cloudsql.client` only — no registry role,
  the image is public). No public compute IPs; SSH exclusively through IAP + OS
  Login. The database has no public IP. Human GCP access + MFA is ⚙️/📋. The single
  public surface is the pack-registry bucket (`packs_registry.tf`) — public **read**
  of pack artifacts only, no write, no listing, and nothing sensitive is ever
  stored there; its publisher SA (`emisar-pack-publisher`) is bucket-scoped
  `objectUser` (objects only — replace archives the prior generation under
  versioning; it cannot touch bucket config or IAM).
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
- **A1 Availability** — a regional MIG (auto-healing, rolling updates) behind an
  anycast HTTPS LB; `instance_count` is workspace-set, and 2+ nodes form one
  BEAM cluster (`Emisar.Cluster.GCE`). Cloud SQL availability per
  `db_availability_type` (`REGIONAL` = synchronous standby + automatic
  failover). DR: automated backups + PITR (RPO minutes) and the whole platform
  as code (re-apply rebuilds it).
- **C1 Confidentiality** — the database is private-IP only; instances read secrets
  from Secret Manager (per-secret least-priv), never from code or metadata. Secret
  *custody* is Terraform Cloud by decision — sensitive workspace variables and
  state — so TFC RBAC + audit is the control that protects them.
- **PI Processing integrity** — DB migrations run under Ecto's advisory lock (one
  runner, others wait); the health check gates traffic so only migrated, healthy
  nodes serve.

## Access & least privilege (configure in GCP)

- **VM service account** (`emisar-vm`): exactly `logging.logWriter`,
  `monitoring.metricWriter`, `compute.viewer` (cluster discovery),
  `cloudsql.client`, and per-secret `secretAccessor`. No Owner/Editor, and no
  registry role (the image is public GHCR). It uses the metadata token — no
  long-lived key.
- **Pack publisher service account** (`emisar-pack-publisher`): exactly
  `roles/storage.objectUser` on the pack-registry bucket — nothing else. Objects
  only (create/get/list/delete — required because republishing the mutable
  `catalog.json` pointer is a replace, and GCS overwrites need `objects.delete`
  even with versioning); it has no bucket-config/IAM permission and no
  project-wide storage role. Versioning archives every generation it replaces;
  install trust rests on the pinned `--hash`, not the registry.
- **Humans**: grant `roles/dns.admin` / project roles to the infra team only; MFA on
  all GCP accounts; SSH via `gcloud compute ssh --tunnel-through-iap` (no keys on the
  box).
- **Terraform Cloud workspace** (org `Dryga` / project `emisar` / workspace
  `emisar`): holds state AND the sensitive secret variables, so membership is
  production access — restrict to the infra team, require 2FA on the TFC org,
  require manual apply approval, keep the TFC audit log.
- **Deploy identity — WIF, configured 2026-07-09, no stored key.** Remote runs
  exchange their OIDC token at pool `terraform-cloud` / provider
  `emisar-workspace`, whose attribute condition pins the trust to
  `organization:Dryga:project:emisar:workspace:emisar` (no other TFC tenant can
  authenticate), with the audience pinned explicitly on both sides. They
  impersonate `terraform@emisar.iam.gserviceaccount.com`, which carries a
  deliberate bundle: `roles/editor` + `roles/resourcemanager.projectIamAdmin`
  (the config manages project IAM + audit config) + `roles/secretmanager.admin`
  + `roles/iam.serviceAccountUser` + `roles/servicenetworking.networksAdmin`
  (Editor lacks `servicenetworking.services.addPeering`, which the private
  services access peering requires — found at first full apply, 2026-07-11)
  + `roles/iam.workloadIdentityPoolAdmin`, `roles/iam.roleAdmin`, and
  `roles/iam.serviceAccountAdmin` (the deploy-identity resources in deploy.tf:
  Editor lacks WIF-pool create, custom-role create, and SA-level setIamPolicy —
  found at the 2026-07-12 apply). Honest note: `projectIamAdmin` makes this SA
  project-admin-equivalent — acceptable because the project is single-purpose
  and the SA is reachable only through the pinned, audit-logged TFC workspace.

## Data protection

Encryption in transit is end-to-end (browser→LB TLS, LB→app internal, app→DB
required-SSL). At rest is Google-managed AES-256 everywhere; for key custody, set
`encryption_key_name` on Cloud SQL / the disk / Secret Manager (CMEK — Open items).
Secret custody is **Terraform Cloud by decision**: externally-issued credentials
(Paddle, Postmark, Sentry, Mixpanel) are sensitive workspace variables, and machine
secrets (SECRET_KEY_BASE, the DB password) are generated in-config — all of which
flow through TFC state into Secret Manager, where the instances read them. TFC
encrypts variables and state at rest and gates them behind workspace RBAC + audit
logs; the compensating rule is in Access above (workspace membership = prod
access). Stronger: Cloud SQL **IAM auth** (no password) via the Auth Proxy — Open
items.

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

The image is **public GHCR by design** — self-hosters run the exact artifact prod
runs, which is a transparency feature, not an oversight. The compensating controls:
the portal's CI runs `sobelow` (Phoenix SAST) + `mix_audit` (dependency CVEs) on
every change; pin `container_image` to a **digest** so a rollout is reproducible
and a registry-side tag mutation can't swap the artifact; Shielded VM guards host
boot integrity. Open item: an image CVE scan (e.g. trivy) in the publish workflow,
since there is no registry-side Container Analysis on GHCR.

## What is NOT in this module (org-level — flagged, not hidden)

SOC 2 Type II also needs controls no Terraform provides: an infosec policy,
periodic access reviews, onboarding/offboarding, vendor/subprocessor management
(Google, HashiCorp/Terraform Cloud, GitHub/GHCR, GoDaddy, Postmark, Paddle,
BetterUptime), incident-response + BCP/DR
runbooks *with evidence they were tested over the period*, risk assessment, change-
approval records, and security training. This module supplies technical evidence for
CC6/CC7/CC8/A1/C1/PI; the rest is process the organization operates and evidences.

## Open items / hardening

- **Portal image publish workflow** — nothing publishes `ghcr.io/andrewdryga/emisar`
  yet (runner/mcp have release workflows; the portal doesn't). Add it, with a
  **trivy CVE scan** in the pipeline (GHCR has no registry-side scanning).
- **CMEK** on Cloud SQL + Secret Manager + disks if key custody is required.
- **Cloud SQL IAM auth** (no password) via the Auth Proxy sidecar in cloud-init.
- **Cloud Armor** WAF + rate-limiting attached to the backend service.
- Wire DMARC/TLS-RPT report inboxes; ramp DMARC → reject and MTA-STS → enforce.
- More alert channels (PagerDuty/Slack) + policies (5xx rate, cert expiry).
