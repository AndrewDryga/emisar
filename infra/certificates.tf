# ── Google-managed TLS via Certificate Manager + DNS authorization ───────────
# The DNS-auth CNAMEs are published into our own Cloud DNS zone (dns.tf), so the
# cert provisions automatically once the zone is authoritative. www and mta-sts
# CNAME to the apex (dns.tf), so they land on this same LB anycast IP — the HTTPS
# proxy selects a cert purely by the certificate_map SNI hostname with no PRIMARY
# fallback, so every served hostname needs its own SAN + cert-map entry or its TLS
# handshake has no cert. Certificate Manager DNS authorization is per-domain.
#
# This map is the answer to "what hostnames do we serve?". Each entry drives a
# DNS authorization here, its CNAME and — where `address_records` is set — an
# A/AAAA pair in dns.tf, and a certificate-map entry below. The GCP resource
# names are written out rather than derived: they are live object names, and a
# derived one that changes by a character replaces the object.
locals {
  served_hostnames = {
    apex = {
      domain             = var.domain
      authorization_name = "emisar-dnsauth"
      description        = "DNS authorization for the emisar managed cert (apex)"
      map_entry_name     = "emisar-certmap-entry"
      address_records    = true
      enabled            = true
    }

    www = {
      domain             = "www.${var.domain}"
      authorization_name = "emisar-dnsauth-www"
      description        = "DNS authorization for www on the emisar managed cert"
      map_entry_name     = "emisar-certmap-entry-www"
      address_records    = false
      enabled            = true
    }

    # Without a cert here, senders fetching https://mta-sts.<domain>/.well-known/
    # mta-sts.txt fail TLS, so the MTA-STS policy is unfetchable and email-TLS
    # enforcement silently no-ops.
    mta_sts = {
      domain             = "mta-sts.${var.domain}"
      authorization_name = "emisar-dnsauth-mta-sts"
      description        = "DNS authorization for mta-sts on the emisar managed cert"
      map_entry_name     = "emisar-certmap-entry-mta-sts"
      address_records    = false
      enabled            = true
    }

    registry = {
      domain             = "registry.${var.domain}"
      authorization_name = "emisar-dnsauth-registry"
      description        = "DNS authorization for the pack-registry serving domain"
      map_entry_name     = "emisar-certmap-entry-registry"
      address_records    = true
      enabled            = true
    }

    livebook = {
      domain             = "livebook.${var.domain}"
      authorization_name = "emisar-dnsauth-livebook"
      description        = "DNS authorization for the private Emisar Livebook workbench"
      map_entry_name     = "emisar-certmap-entry-livebook"
      address_records    = true
      enabled            = var.livebook_enabled
    }
  }

  # The hostnames actually created, for this file and dns.tf.
  active_hostnames = { for key, host in local.served_hostnames : key => host if host.enabled }

  # Which certificate serves each hostname. Kept apart from served_hostnames on
  # purpose: the certificates depend on the authorizations, so a single map
  # holding both would be a cycle.
  hostname_certificates = {
    apex     = google_certificate_manager_certificate.emisar.id
    www      = google_certificate_manager_certificate.emisar.id
    mta_sts  = google_certificate_manager_certificate.emisar.id
    registry = google_certificate_manager_certificate.registry.id
    livebook = one(google_certificate_manager_certificate.livebook[*].id)
  }
}

resource "google_certificate_manager_dns_authorization" "served" {
  for_each = local.active_hostnames

  name        = each.value.authorization_name
  domain      = each.value.domain
  description = each.value.description
  depends_on  = [google_project_service.apis]
}

resource "google_certificate_manager_certificate" "emisar" {
  name = "emisar-cert"
  managed {
    domains = [var.domain, "www.${var.domain}", "mta-sts.${var.domain}"]
    dns_authorizations = [
      google_certificate_manager_dns_authorization.served["apex"].id,
      google_certificate_manager_dns_authorization.served["www"].id,
      google_certificate_manager_dns_authorization.served["mta_sts"].id,
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
    dns_authorizations = [google_certificate_manager_dns_authorization.served["livebook"].id]
  }
  depends_on = [google_project_service.apis]
}

# registry.<domain> gets its OWN managed cert, not a new SAN on the emisar cert:
# adding a SAN re-provisions the existing cert, briefly risking apex TLS during
# replacement for a hostname that has nothing to do with the console. The shared
# certificate map selects certs purely by SNI, so an independent cert + map entry
# is the isolation-preserving way to add a served hostname.
resource "google_certificate_manager_certificate" "registry" {
  name = "emisar-cert-registry"
  managed {
    domains            = ["registry.${var.domain}"]
    dns_authorizations = [google_certificate_manager_dns_authorization.served["registry"].id]
  }
  depends_on = [google_project_service.apis]
}

resource "google_certificate_manager_certificate_map" "emisar" {
  name       = "emisar-certmap"
  depends_on = [google_project_service.apis]
}

# One entry per served SNI hostname (no PRIMARY matcher) — an SNI with no matching
# entry gets no cert and the handshake fails.
resource "google_certificate_manager_certificate_map_entry" "served" {
  for_each = local.active_hostnames

  name         = each.value.map_entry_name
  map          = google_certificate_manager_certificate_map.emisar.name
  certificates = [local.hostname_certificates[each.key]]
  hostname     = each.value.domain
}

moved {
  from = google_certificate_manager_dns_authorization.emisar
  to   = google_certificate_manager_dns_authorization.served["apex"]
}

moved {
  from = google_certificate_manager_dns_authorization.www
  to   = google_certificate_manager_dns_authorization.served["www"]
}

moved {
  from = google_certificate_manager_dns_authorization.mta_sts
  to   = google_certificate_manager_dns_authorization.served["mta_sts"]
}

moved {
  from = google_certificate_manager_dns_authorization.registry
  to   = google_certificate_manager_dns_authorization.served["registry"]
}

moved {
  from = google_certificate_manager_dns_authorization.livebook[0]
  to   = google_certificate_manager_dns_authorization.served["livebook"]
}

moved {
  from = google_certificate_manager_certificate_map_entry.emisar
  to   = google_certificate_manager_certificate_map_entry.served["apex"]
}

moved {
  from = google_certificate_manager_certificate_map_entry.www
  to   = google_certificate_manager_certificate_map_entry.served["www"]
}

moved {
  from = google_certificate_manager_certificate_map_entry.mta_sts
  to   = google_certificate_manager_certificate_map_entry.served["mta_sts"]
}

moved {
  from = google_certificate_manager_certificate_map_entry.registry
  to   = google_certificate_manager_certificate_map_entry.served["registry"]
}

moved {
  from = google_certificate_manager_certificate_map_entry.livebook[0]
  to   = google_certificate_manager_certificate_map_entry.served["livebook"]
}
