# infra — production readiness & SOC 2 control mapping

Scope: the DNS infrastructure in `infra/` (the Cloud DNS zone for `emisar.dev`).
emisar's app/LB/TLS run on Fly.io and have their own posture; this document is
about the DNS layer and the controls it implements or enables.

**Honest framing.** SOC 2 is an *organizational* attestation over a period of
time — auditors examine policies, people, and operations, not just code. No repo
"passes SOC 2." What this module does is implement the **technical controls** a
SOC 2 auditor looks for in a DNS/IaC system, and produce **evidence** (reviewed
IaC, a change-management gate, audit trails). The table below is honest about
what's enforced in code, what's a provider/console setting you must configure,
and what's an org-level control that lives outside this repo entirely.

Legend: ✅ enforced in this module · ⚙️ configure in the provider (documented
here) · 📋 org/process control, outside code.

## Production-readiness checklist

| Item | Status | Where / evidence |
|---|---|---|
| DNSSEC signing (ECDSA P-256/SHA-256, NSEC3) | ✅ | `dns.tf` zone `dnssec_config`; DS via `dnssec_ds_record` output |
| CAA — issuance restricted to Let's Encrypt + iodef | ✅ | `dns.tf`; both Fly + BetterUptime certs verified as LE |
| SPF + DKIM (Google + Postmark) + Return-Path | ✅ | `dns.tf` |
| DMARC (ramped none→quarantine→reject) | ✅ | `dns.tf`, `var.dmarc_policy` |
| SMTP-TLS reporting (TLS-RPT) | ✅ | `dns.tf` |
| MTA-STS (testing mode; enforce after cert + ramp) | ✅ | policy in portal + `mta-sts`/`_mta-sts` in `dns.tf` |
| Highly available authoritative DNS | ⚙️ | Cloud DNS anycast (100% SLA); no single point we run |
| Reproducible, versioned infra (IaC) | ✅ | whole module; `git log` is the change record |
| Zone applied + verified in GCP (staged) | ✅ | `apply` clean (19 added); verify-cutover all-green; DNSSEC signing live (alg 13) |
| Change-management gate | ✅ | `.github/workflows/infra-ci.yml` (fmt + validate + tflint) |
| No secrets in state or git | ✅ | module has none; `.gitignore` blocks `*.tfstate`/`*.tfvars` |
| State encrypted + access-controlled | ✅ | GCS `emisar-tfstate` — UBLA + public-access-prevention + versioned |
| Least-privilege apply identity | ⚙️ | GCP IAM — see Access below (dns.admin, not owner) |
| Change audit trail | ✅ | git + PR review + versioned GCS state + GCP Cloud Audit Logs |
| Monitoring & alerting | 📋/⚙️ | see Monitoring below |
| Backup / disaster recovery | ✅ | zone is code; `terraform apply` rebuilds it |

## SOC 2 Trust Services Criteria — how the DNS layer maps

- **CC8.1 Change management** — the strongest code-demonstrable control here.
  Every zone change flows: branch → PR → `infra CI` (fmt/validate/tflint) green →
  human review → merge → `terraform apply` by an authorized operator. No direct
  console edits (Cloud DNS is authoritative from this code; a hand edit is
  unreviewed and gets overwritten). Evidence: PR history + the versioned GCS state
  (every apply is a new object generation) + GCP Cloud Audit Logs. Running apply
  from a CI job with Workload Identity Federation would add an approval-gated,
  logged runner — see Access.
- **CC6 Logical access** — least-privilege apply identity (⚙️ Access, below); the
  state bucket is IAM-controlled with uniform bucket-level access and public-access
  prevention; MFA on human GCP accounts; no long-lived credentials in CI (CI is
  credential-free by design). Registrar (GoDaddy) account MFA is 📋.
- **CC7 System operations / monitoring** — DMARC `rua`, TLS-RPT `rua`, and CAA
  `iodef` turn misuse (spoofing, downgrade, unauthorized cert issuance) into
  signals; GCP Cloud Audit Logs record every zone mutation; uptime/cert/DNSSEC
  monitors (below) detect availability + integrity failures.
- **CC6.1 / CC6.7 Data integrity & transmission** — **DNSSEC** makes resolver
  answers tamper-evident (cache-poisoning / spoofing defense); **CAA** constrains
  who may issue certs for the name and every subdomain; email is authenticated
  end-to-end (SPF + two DKIM keys + DMARC), which for a magic-link product is an
  account-takeover-phishing control, not just deliverability.
- **A1 Availability** — Cloud DNS is anycast with a 100% uptime SLA; the zone
  itself is code, so recovery is a re-apply (DR below).
- **C1 Confidentiality** — no secrets live in this module, its state, or git;
  anything sensitive (Fly/GCP/Postmark tokens) lives in the respective secret
  store, referenced, never inlined.

## Access & least privilege (configure in GCP)

- **GCP:** the apply identity needs `roles/dns.admin` on the project, plus — for
  the *first* apply only — `roles/serviceusage.serviceUsageAdmin` to enable the
  DNS API. **Not** Owner/Editor. Prefer **Workload Identity Federation** (short-
  lived, keyless — e.g. from a GitHub Actions apply job) over a service-account
  JSON key; if a key is unavoidable, scope it to that SA and rotate it. MFA on all
  human GCP accounts.
- **State bucket (`emisar-tfstate`):** uniform bucket-level access,
  public-access-prevention, and object versioning are enforced; grant
  `roles/storage.objectAdmin` on just this bucket to the apply identity. Access to
  the bucket IS access to change production DNS — treat it that way.
- **CI:** holds no credentials and can't apply — it only lints/validates. Nothing
  to leak.

## Audit logging & evidence retention

Every change to production DNS is recorded three ways: the **git commit** (author,
reviewed diff), the **GCS state history** (each apply is a new versioned object),
and **GCP Cloud Audit Logs** (Admin Activity for `dns.*` — every zone mutation).
Admin Activity logs are always-on and retained **400 days in the immutable
`_Required` bucket by default** — no config, and that already covers change-audit
retention for a typical SOC 2 period. Add a sink to BigQuery / a log bucket only
for longer retention or SIEM export.

## Monitoring & alerting (mostly ops — set these up)

- **Availability/integrity monitors:** apex + `www` resolve, MX resolves, DNSSEC
  validates (AD flag present), and TLS cert expiry alerts at <30 days. The public
  status page (`status.emisar.dev`, BetterUptime) already watches the app; add
  these DNS/cert checks alongside it.
- **Email-auth signal:** point the DMARC `rua` and TLS-RPT `rua` at a monitored
  inbox or a DMARC service and review the reports **before** ramping
  `var.dmarc_policy` past `none`.
- **Unauthorized issuance:** CAA `iodef` reports go to `security@emisar.dev` —
  which must actually be provisioned (it's also the disclosure address).

## Backup & disaster recovery

The zone is fully described in code, so recovery is `terraform apply` (minutes),
and the GCS state is versioned and restorable. The only manual re-steps
are the NS delegation and the DNSSEC DS at the registrar. RPO ≈ last commit; RTO ≈
apply + propagation. Worth a periodic game-day: apply into a scratch zone and
confirm it reproduces.

## What is NOT in this module (org-level — flagged, not hidden)

A SOC 2 audit also needs controls that no Terraform can provide: an infosec
policy, periodic access reviews, onboarding/offboarding, vendor/subprocessor
management (GoDaddy, Fly, Google Workspace, Postmark, BetterUptime, Terraform
Cloud), incident-response and BCP/DR runbooks with evidence they're tested, risk
assessment, and security training. This module supplies technical evidence for a
slice of CC6/CC7/CC8/A1/C1; the rest is process the organization owns.

## Open items

- **MTA-STS → enforce** — policy + DNS ship in `mode: testing`. Run
  `fly certs add mta-sts.emisar.dev`, then flip the policy file to `mode: enforce`
  and bump the `_mta-sts` `id` once TLS-RPT reports are clean.
- **Wire the report inboxes** — DMARC `rua`, TLS-RPT `rua`; then ramp DMARC
  `none → quarantine → reject` once reports confirm Postmark + Workspace align.
- **Provision `security@emisar.dev`** — CAA iodef target and disclosure address.
- **Choose Workload Identity Federation** for the apply identity (avoid a
  long-lived SA key), ideally from a CI apply job. A Cloud Audit Logs sink is
  optional — Admin Activity is already retained 400 days by default (above).
