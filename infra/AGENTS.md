# infra — agent manual

Terraform for emisar's **Google Cloud DNS** zone (`emisar.dev`). DNS only —
emisar's app, LB, and TLS run on Fly.io. Read `README.md` for the full picture;
this file is the rules.

## Gate

```bash
terraform fmt -check -recursive
terraform init -backend=false && terraform validate
tflint --init && tflint
```

All three must pass before commit — and CI (`.github/workflows/infra-ci.yml`)
runs exactly this on every PR that touches `infra/`, with no cloud credentials
(`-backend=false`), so the change-management gate can't be skipped. `validate`
needs the providers, which `init` downloads. A live `plan`/`apply` is the
separate, creds-gated deploy step (GCS backend, operator-run apply) — never
commit on the strength of a local apply alone.

Production-readiness and the SOC 2 control mapping live in `COMPLIANCE.md`; keep
it honest and current when you change what the zone enforces.

## Non-negotiable rules

1. **The zone is authoritative — replicate before you cut over.** Once the
   registrar delegates to this zone, ONLY records in `dns.tf` resolve. Adding a
   record at the registrar without adding it here means it vanishes at the next
   apply. Any record that exists at GoDaddy must exist here first.
2. **Never touch the Fly records blindly.** `_acme-challenge` (CNAME → flydns) and
   `_fly-ownership` (TXT) are how Fly issues and proves the TLS cert. Breaking
   them breaks HTTPS on the whole site. The apex `A`/`AAAA` are Fly's LB IPs.
3. **DNSSEC DS is published LAST.** Enable signing on the zone, delegate NS,
   confirm resolution, *then* add the DS at the registrar. A DS ahead of working
   delegation takes the domain offline. Cloud DNS owns the keys; we only emit the DS.
4. **DMARC ramps, never jumps.** `none → quarantine → reject`, gated on clean
   `rua` reports. Shipping `reject` without evidence drops legitimate mail.
5. **CAA is inherited by subdomains.** Every subdomain's issuing CA must be in
   `var.caa_issuers` (today: Let's Encrypt, covering Fly + BetterUptime). Add the
   CA before pointing a new subdomain at a host that uses a different one.
6. **No secrets, no state in git.** `*.tfstate*`, `terraform.tfvars`, and
   `.terraform/` are git-ignored; keep it that way. This module has no secrets —
   don't introduce one (put anything sensitive in Secret Manager, referenced, not
   inlined).
7. **DKIM/long TXT stays chunked via `regexall`.** Don't hand-split a key across
   255-char strings — the `format(... join(... regexall(".{1,255}", key)))`
   pattern in `dns.tf` does it correctly. Miscounting a boundary silently breaks
   signature verification.

## House style

Match `../onlytty/infra`: comments explain **why** (the abuse case, the ordering
hazard), never restate the resource. One record, one clearly-labelled resource.
Values that vary or carry a security decision (Fly IPs, DMARC policy, CAA
issuers) are variables with a description that IS the documentation; emisar's live
values are the defaults.
