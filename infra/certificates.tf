# ── Google-managed TLS via Certificate Manager + DNS authorization ───────────
# The DNS-auth CNAMEs are published into our own Cloud DNS zone (dns.tf), so the
# cert provisions automatically once the zone is authoritative. www and mta-sts
# CNAME to the apex (dns.tf), so they land on this same LB anycast IP — the HTTPS
# proxy selects a cert purely by the certificate_map SNI hostname with no PRIMARY
# fallback, so every served hostname needs its own SAN + cert-map entry or its TLS
# handshake has no cert. Certificate Manager DNS authorization is per-domain.
resource "google_certificate_manager_dns_authorization" "emisar" {
  name        = "emisar-dnsauth"
  domain      = var.domain
  description = "DNS authorization for the emisar managed cert (apex)"
  depends_on  = [google_project_service.apis]
}

resource "google_certificate_manager_dns_authorization" "www" {
  name        = "emisar-dnsauth-www"
  domain      = "www.${var.domain}"
  description = "DNS authorization for www on the emisar managed cert"
  depends_on  = [google_project_service.apis]
}

# Without a cert here, senders fetching https://mta-sts.<domain>/.well-known/
# mta-sts.txt fail TLS, so the MTA-STS policy is unfetchable and email-TLS
# enforcement silently no-ops.
resource "google_certificate_manager_dns_authorization" "mta_sts" {
  name        = "emisar-dnsauth-mta-sts"
  domain      = "mta-sts.${var.domain}"
  description = "DNS authorization for mta-sts on the emisar managed cert"
  depends_on  = [google_project_service.apis]
}

resource "google_certificate_manager_dns_authorization" "livebook" {
  count = var.livebook_enabled ? 1 : 0

  name        = "emisar-dnsauth-livebook"
  domain      = "livebook.${var.domain}"
  description = "DNS authorization for the private Emisar Livebook workbench"
  depends_on  = [google_project_service.apis]
}

resource "google_certificate_manager_certificate" "emisar" {
  name = "emisar-cert"
  managed {
    domains = [var.domain, "www.${var.domain}", "mta-sts.${var.domain}"]
    dns_authorizations = [
      google_certificate_manager_dns_authorization.emisar.id,
      google_certificate_manager_dns_authorization.www.id,
      google_certificate_manager_dns_authorization.mta_sts.id,
    ]
  }
  depends_on = [google_project_service.apis]
}

# Keep this certificate independent: adding an admin-only hostname must not
# replace the public portal certificate or risk its serving path.
resource "google_certificate_manager_certificate" "livebook" {
  count = var.livebook_enabled ? 1 : 0

  name = "emisar-livebook-cert"
  managed {
    domains            = ["livebook.${var.domain}"]
    dns_authorizations = [google_certificate_manager_dns_authorization.livebook[0].id]
  }
  depends_on = [google_project_service.apis]
}

resource "google_certificate_manager_certificate_map" "emisar" {
  name       = "emisar-certmap"
  depends_on = [google_project_service.apis]
}

# One entry per served SNI hostname (no PRIMARY matcher) — an SNI with no matching
# entry gets no cert and the handshake fails.
resource "google_certificate_manager_certificate_map_entry" "emisar" {
  name         = "emisar-certmap-entry"
  map          = google_certificate_manager_certificate_map.emisar.name
  certificates = [google_certificate_manager_certificate.emisar.id]
  hostname     = var.domain
}

resource "google_certificate_manager_certificate_map_entry" "www" {
  name         = "emisar-certmap-entry-www"
  map          = google_certificate_manager_certificate_map.emisar.name
  certificates = [google_certificate_manager_certificate.emisar.id]
  hostname     = "www.${var.domain}"
}

resource "google_certificate_manager_certificate_map_entry" "mta_sts" {
  name         = "emisar-certmap-entry-mta-sts"
  map          = google_certificate_manager_certificate_map.emisar.name
  certificates = [google_certificate_manager_certificate.emisar.id]
  hostname     = "mta-sts.${var.domain}"
}

resource "google_certificate_manager_certificate_map_entry" "livebook" {
  count = var.livebook_enabled ? 1 : 0

  name         = "emisar-certmap-entry-livebook"
  map          = google_certificate_manager_certificate_map.emisar.name
  certificates = [google_certificate_manager_certificate.livebook[0].id]
  hostname     = "livebook.${var.domain}"
}

