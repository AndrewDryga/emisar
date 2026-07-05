# ── emisar public DNS — the authoritative Cloud DNS zone for emisar.dev ───────
#
# Delegating the registrar (GoDaddy) nameservers to this zone makes Cloud DNS
# authoritative, so ONLY the records defined here resolve.
#
# The apex A/AAAA point at the Google HTTPS load balancer (lb.tf); the Certificate
# Manager DNS-auth CNAME proves domain control for the Google-managed cert. The
# email records (MX / SPF / two DKIM / Postmark Return-Path / DMARC / CAA / TLS-RPT
# / MTA-STS) are provider-independent and carry over unchanged — a spoofable domain
# is an account-takeover phishing vector for a magic-link product.
#
# Dropped on purpose:
#   • NS / SOA at the apex — Cloud DNS serves its own (see the `nameservers` output).
#   • the old Fly `_acme-challenge` / `_fly-ownership` records — replaced by the
#     Certificate Manager DNS authorization above; emisar's TLS is the GCP LB now.

resource "google_dns_managed_zone" "emisar" {
  name        = "emisar"
  dns_name    = var.dns_name
  description = "emisar public zone — authoritative DNS for ${var.domain}"

  # Explicit — this zone is intentionally internet-facing (public authoritative DNS).
  visibility = "public"

  # DNSSEC with modern elliptic-curve signing (ECDSA P-256 / SHA-256): smaller,
  # faster-to-validate signatures than the RSA default, and Cloud DNS rotates the
  # keys for us. NSEC3 answers denial-of-existence without exposing the zone to
  # trivial walking. We publish only the resulting DS at the registrar (see the
  # `dnssec_ds_record` output) — do that step LAST, after the nameserver
  # delegation is confirmed resolving, or a DS pointing at a zone resolvers can't
  # yet reach takes the domain down.
  dnssec_config {
    state         = "on"
    non_existence = "nsec3"

    default_key_specs {
      key_type   = "keySigning"
      algorithm  = "ecdsap256sha256"
      key_length = 256
    }
    default_key_specs {
      key_type   = "zoneSigning"
      algorithm  = "ecdsap256sha256"
      key_length = 256
    }
  }

  # This zone IS emisar.dev's DNS — destroying it drops every record and breaks the
  # DNSSEC chain of trust at the registrar. Deletion must be a deliberate, code-
  # reviewed act (remove this block on purpose), never a stray `terraform destroy`
  # or an in-place resource replacement.
  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.apis]
}

# ── Apex A/AAAA → Google HTTPS load balancer (anycast) ───────────────────────
resource "google_dns_record_set" "a" {
  name         = "${var.domain}."
  managed_zone = google_dns_managed_zone.emisar.name
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.ipv4.address]
}

resource "google_dns_record_set" "aaaa" {
  name         = "${var.domain}."
  managed_zone = google_dns_managed_zone.emisar.name
  type         = "AAAA"
  ttl          = 300
  rrdatas      = [google_compute_global_address.ipv6.address]
}

# www → apex (the LB redirects the canonical bare domain).
resource "google_dns_record_set" "www" {
  name         = "www.${var.domain}."
  managed_zone = google_dns_managed_zone.emisar.name
  type         = "CNAME"
  ttl          = 3600
  rrdatas      = ["${var.domain}."]
}

# ── TLS: Certificate Manager DNS authorization ────────────────────────────────
# Proves domain control so the Google-managed cert (lb.tf) provisions. Published
# into our own zone, so the cert goes ACTIVE minutes after the NS delegation.
resource "google_dns_record_set" "cert_auth" {
  name         = google_certificate_manager_dns_authorization.emisar.dns_resource_record[0].name
  managed_zone = google_dns_managed_zone.emisar.name
  type         = google_certificate_manager_dns_authorization.emisar.dns_resource_record[0].type
  ttl          = 300
  rrdatas      = [google_certificate_manager_dns_authorization.emisar.dns_resource_record[0].data]
}

# ── Google Workspace inbound mail ─────────────────────────────────────────────
resource "google_dns_record_set" "mx" {
  name         = "${var.domain}."
  managed_zone = google_dns_managed_zone.emisar.name
  type         = "MX"
  ttl          = 3600
  rrdatas = [
    "1 aspmx.l.google.com.",
    "5 alt1.aspmx.l.google.com.",
    "5 alt2.aspmx.l.google.com.",
    "10 alt3.aspmx.l.google.com.",
    "10 alt4.aspmx.l.google.com.",
  ]
}

# ── SPF + Google site verification (one apex TXT set, two strings) ────────────
resource "google_dns_record_set" "txt_apex" {
  name         = "${var.domain}."
  managed_zone = google_dns_managed_zone.emisar.name
  type         = "TXT"
  ttl          = 3600
  rrdatas = [
    "\"v=spf1 include:dc-aa8e722993._spfm.${var.domain} ~all\"",
    "\"google-site-verification=z7NfVdQh3n7LjvKbTdsuDIYP3yi5URyeYdGGbdeTbcc\"",
  ]
}

# The SPF-flattening subdomain the apex SPF `include:`s (kept verbatim from
# GoDaddy). Postmark is NOT in the apex SPF on purpose — it authenticates on its
# own Return-Path (`pm-bounces`, below), which relaxed-aligns to the domain.
resource "google_dns_record_set" "txt_spf_include" {
  name         = "dc-aa8e722993._spfm.${var.domain}."
  managed_zone = google_dns_managed_zone.emisar.name
  type         = "TXT"
  ttl          = 3600
  rrdatas      = ["\"v=spf1 include:_spf.google.com ~all\""]
}

# ── DKIM ──────────────────────────────────────────────────────────────────────
# The public keys exceed the 255-char per-string DNS limit, so each is published
# as several quoted <=255-char strings in one TXT record (the Cloud DNS multi-
# string form; DKIM verifiers concatenate them). regexall chunks the key and
# format/join wrap the chunks as "part1" "part2" — so we never hand-split and
# miscount a boundary.
locals {
  google_dkim_key   = "v=DKIM1;k=rsa;p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA748bSVjvw37DET/fj6OX2avATuCae+N/k/sBM3tvh7X0THGnAeBn+1B09bsRKlGXMtdoEDO6nkXxho0ioH/987dyK9Ug70vJ6+fkVpLDJzsG8wDFyttACq3bevGkwYWTms5mo5XUJ/8SyuHJ4agF3eCJBAGw/CH7bYzn+P7jAxk3cygAiGVwIZHlSY4JJn7MEplLIXJnPg1eF0z1411q/beso1OKWxdWztbCr0XSBYFLsXvrEv1L1e/tCqY2R3fWqQGbcOUWnVQqCR6UZd5I+IbHe1ngDEtx0ITDwo2GaaWi+sYwZZ2ioCIFbBZSh2+oyDZsz+1sNF/8lkoJVoOySwIDAQAB"
  postmark_dkim_key = "k=rsa;p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCDVJWgX6r7dOIKg7geU3m/ANfqXrd0g0/PE6pPwpSBcHeKnVZ0gU56M9EisM7Tbb0Fey1Vqc/3UtAA6lwac3pmg16SZJKqKbW7eFQMfjv6iw7j5V2NOblYk9HmfbPoKfK8hN/oOSfQGq4yCqHiJqfKXVD+ZjMe3S6wNgyJ8GLM/QIDAQAB"

  google_dkim_txt   = format("\"%s\"", join("\" \"", regexall(".{1,255}", local.google_dkim_key)))
  postmark_dkim_txt = format("\"%s\"", join("\" \"", regexall(".{1,255}", local.postmark_dkim_key)))
}

# Google Workspace DKIM.
resource "google_dns_record_set" "dkim_google" {
  name         = "google._domainkey.${var.domain}."
  managed_zone = google_dns_managed_zone.emisar.name
  type         = "TXT"
  ttl          = 3600
  rrdatas      = [local.google_dkim_txt]
}

# Postmark DKIM (transactional mail — magic-link sign-in, notifications). The
# selector is the dated one Postmark issued for this domain.
resource "google_dns_record_set" "dkim_postmark" {
  name         = "20260603061232pm._domainkey.${var.domain}."
  managed_zone = google_dns_managed_zone.emisar.name
  type         = "TXT"
  ttl          = 3600
  rrdatas      = [local.postmark_dkim_txt]
}

# Postmark custom Return-Path — SPF authenticates outbound Postmark mail on this
# subdomain, which relaxed-aligns to emisar.dev for DMARC. (This is why Postmark
# needs no entry in the apex SPF above.)
resource "google_dns_record_set" "pm_bounces" {
  name         = "pm-bounces.${var.domain}."
  managed_zone = google_dns_managed_zone.emisar.name
  type         = "CNAME"
  ttl          = 3600
  rrdatas      = ["pm.mtasv.net."]
}

# ── DMARC ─────────────────────────────────────────────────────────────────────
# Was absent at GoDaddy. adkim/aspf=r (relaxed) is required so Postmark's
# subdomain Return-Path aligns. Start at p=none and ramp — see var.dmarc_policy.
resource "google_dns_record_set" "dmarc" {
  name         = "_dmarc.${var.domain}."
  managed_zone = google_dns_managed_zone.emisar.name
  type         = "TXT"
  ttl          = 3600
  rrdatas      = ["\"v=DMARC1; p=${var.dmarc_policy}; adkim=r; aspf=r; rua=${var.dmarc_rua}; fo=1\""]
}

# ── SMTP TLS reporting (TLS-RPT) ──────────────────────────────────────────────
# Daily report of any TLS negotiation failures delivering to our MX — the report
# channel MTA-STS (below) leans on while it is in testing mode.
resource "google_dns_record_set" "tlsrpt" {
  name         = "_smtp._tls.${var.domain}."
  managed_zone = google_dns_managed_zone.emisar.name
  type         = "TXT"
  ttl          = 3600
  rrdatas      = ["\"v=TLSRPTv1; rua=mailto:tls-reports@${var.domain}\""]
}

# ── MTA-STS — enforce TLS on inbound mail to our Google MX ────────────────────
# The policy is served at https://mta-sts.emisar.dev/.well-known/mta-sts.txt by
# the portal (priv/static/.well-known/mta-sts.txt), so `mta-sts` points at the
# same Fly app as the apex. Ships in `mode: testing` — failures are reported via
# TLS-RPT above but NO mail is blocked; flip the policy file to `mode: enforce`
# AND bump the `id` below once the reports are clean (the DMARC ramp discipline,
# for mail-in-transit). Activation needs a cert for the host:
# `fly certs add mta-sts.emisar.dev`.
resource "google_dns_record_set" "mta_sts_host" {
  name         = "mta-sts.${var.domain}."
  managed_zone = google_dns_managed_zone.emisar.name
  type         = "CNAME"
  ttl          = 3600
  rrdatas      = ["${var.domain}."]
}

resource "google_dns_record_set" "mta_sts_txt" {
  name         = "_mta-sts.${var.domain}."
  managed_zone = google_dns_managed_zone.emisar.name
  type         = "TXT"
  ttl          = 3600
  # Bump this id whenever mta-sts.txt changes, so senders re-fetch the policy.
  rrdatas = ["\"v=STSv1; id=20260705000000\""]
}

# ── CAA — restrict certificate issuance ───────────────────────────────────────
# Issuers in use: the Google-managed LB cert comes from Google Trust Services
# (`pki.goog`), and the BetterUptime status page (status.) from Let's Encrypt —
# both in var.caa_issuers. iodef sends any violation report to the security
# disclosure inbox. Mind the inheritance note on var.caa_issuers before adding a
# subdomain on another host.
resource "google_dns_record_set" "caa" {
  name         = "${var.domain}."
  managed_zone = google_dns_managed_zone.emisar.name
  type         = "CAA"
  ttl          = 3600
  rrdatas = concat(
    [for ca in var.caa_issuers : "0 issue \"${ca}\""],
    ["0 iodef \"mailto:security@${var.domain}\""],
  )
}

# ── Status page (BetterUptime / BetterStack) ──────────────────────────────────
resource "google_dns_record_set" "status" {
  name         = "status.${var.domain}."
  managed_zone = google_dns_managed_zone.emisar.name
  type         = "CNAME"
  ttl          = 3600
  rrdatas      = ["statuspage.betteruptime.com."]
}
