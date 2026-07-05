# infra — emisar DNS on Google Cloud DNS

The authoritative public DNS zone for **emisar.dev**, managed in Terraform on
**Google Cloud DNS**. This module owns DNS and nothing else: emisar's app, load
balancer, and TLS run on **Fly.io**, so there is no GCP compute/LB/cert stack
here (that's the shape of `../onlytty/infra`, whose app is served from GCP —
emisar's is not). Cloud DNS just answers queries; Fly serves the traffic.

```
              ┌─ Cloud DNS (authoritative zone, DNSSEC-signed) ─┐
registrar NS ─┤  A/AAAA → Fly LB   ·   MX → Google Workspace     ├─► emisar.dev
 (GoDaddy)    │  SPF/DKIM/DMARC    ·   _acme-challenge → Fly TLS  │
              └──────────────────────────────────────────────────┘
```

## What's in the zone

Every record was ported 1:1 from the GoDaddy export, plus the security records
that were missing there. `dns.tf` is the source of truth; this is the map.

| Record | Purpose |
|---|---|
| `A` / `AAAA` @ | Fly.io dedicated LB IPs (`var.fly_ipv4` / `var.fly_ipv6`) |
| `www` CNAME | → apex |
| `MX` @ | Google Workspace inbound mail |
| `TXT` @ (SPF) | `v=spf1 include:…_spfm…` → flattens to Google; **Postmark is intentionally not here** |
| `TXT` `dc-…._spfm` | the SPF-flatten target (→ `_spf.google.com`) |
| `TXT` `google._domainkey` | Google Workspace DKIM |
| `TXT` `20260603061232pm._domainkey` | Postmark DKIM (transactional mail) |
| `CNAME` `pm-bounces` | Postmark custom Return-Path (SPF alignment for Postmark) |
| `CNAME` `_acme-challenge` | Fly ACME DNS-01 — **required for Fly cert renewal** |
| `TXT` `_fly-ownership` | Fly domain-ownership proof |
| `CNAME` `status` | BetterUptime status page |
| **`TXT` `_dmarc`** | **added** — DMARC policy (ramped; see below) |
| **`CAA` @** | **added** — restrict issuance to Let's Encrypt + iodef to security@ |
| **`TXT` `_smtp._tls`** | **added** — SMTP-TLS failure reporting |
| **DNSSEC** | **added** — zone signed; DS goes to the registrar |

**Dropped from GoDaddy on purpose:** the apex `NS`/`SOA` (Cloud DNS serves its
own) and `_domainconnect` (GoDaddy Domain Connect autoconfig, meaningless here).

## Email authentication, in one paragraph

emisar receives mail via **Google Workspace** (MX) and sends transactional mail
(magic-link sign-in, notifications) via **Postmark** from `no-reply@emisar.dev`.
Both are DKIM-signed (two `_domainkey` records). SPF authorizes Google at the
apex; Postmark authenticates on its own `pm-bounces` Return-Path, which
relaxed-aligns to the domain — so **don't add Postmark to the apex SPF**, that's
a common and unnecessary "fix". DMARC ties it together. Because the product's
core email is a sign-in link, an unauthenticated domain is a real account-
takeover phishing surface — which is why DMARC/CAA/DNSSEC are non-negotiable here.

## Status & registrar cutover

The zone is **applied** to the `emisar` GCP project (state in the `emisar-tfstate`
GCS bucket — see `main.tf`; Terraform uses your gcloud Application Default
Credentials, no separate login). It is **staged**: it answers on its own Cloud DNS
nameservers, but emisar.dev still resolves through GoDaddy until the nameservers
are delegated — so the apply has **no effect on the live domain**.

Re-apply after a change:

```bash
cp terraform.tfvars.example terraform.tfvars   # project_id = emisar
terraform init      # connects to the GCS backend
terraform apply
```

Going live — the one irreversible, registrar-side step:

```bash
# 1. Confirm the staged zone replicates live — must be all-green:
./scripts/verify-cutover.sh "$(terraform output -raw nameservers | head -1)"

# 2. Delegate: set these NS at GoDaddy (Nameservers → "I'll use my own"):
terraform output nameservers

# 3. AFTER delegation resolves, verify, THEN finish DNSSEC:
dig +short NS emisar.dev            # the four Cloud DNS nameservers
dig +short emisar.dev               # still the Fly IP
terraform output dnssec_ds_record   # add this DS at GoDaddy → DNSSEC (do it LAST)
```

**Order matters.** Delegate nameservers and confirm the zone resolves *before*
adding the DNSSEC DS at the registrar — a DS pointing at a zone resolvers can't
yet validate is the classic way to take a domain fully offline. Cloud DNS manages
the signing keys; you only ever publish the DS. `terraform output next_steps`
prints this with live values.

## DMARC ramp

`var.dmarc_policy` defaults to `none` — publish it, watch the `rua` aggregate
reports for a couple of weeks, confirm Postmark + Workspace both show `pass` and
`aligned`, then move `none → quarantine → reject`. Point `var.dmarc_rua` at a
monitored inbox or a DMARC service (Postmark offers a free monitor). Don't jump
to `reject` blind — that's how you drop your own legitimate mail.

## MTA-STS

Both the policy and its DNS ship here. The portal serves the policy at
`https://mta-sts.emisar.dev/.well-known/mta-sts.txt`
(`portal/apps/emisar_web/priv/static/.well-known/mta-sts.txt`); `mta-sts` and
`_mta-sts` are in the zone. It starts in **`mode: testing`** — TLS failures are
reported (via TLS-RPT) but no mail is ever blocked. Two steps to go to enforce:

1. **Activate the host cert:** `fly certs add mta-sts.emisar.dev` (needed for the
   policy URL to serve over HTTPS). Until then senders just can't fetch the
   policy — same as no MTA-STS, no harm.
2. **Flip to enforce:** once TLS-RPT reports are clean, change the policy file to
   `mode: enforce` **and** bump the `id` in the `_mta-sts` TXT so senders
   re-fetch. Same ramp discipline as DMARC.

## Validate locally

```bash
terraform fmt -check -recursive
terraform init -backend=false && terraform validate
tflint --init && tflint
```

CI (`.github/workflows/infra-ci.yml`) runs the same three checks on every PR with
no cloud credentials, so nothing reaches the zone unreviewed. State lives in the
versioned, private `emisar-tfstate` GCS bucket; `terraform.tfvars` and `*.tfstate*`
are git-ignored. No secrets live in this module — the only sensitive-looking
output, the DNSSEC DS, is public by design.

## Production readiness & SOC 2

`COMPLIANCE.md` maps this layer to the SOC 2 Trust Services Criteria — change
management, DNSSEC/CAA/email-auth integrity, least-privilege access, audit
trails, monitoring, and DR — and is honest about which controls are enforced in
code versus configured in the provider or owned by the organization.
