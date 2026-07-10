# ── Global anycast IPs (IPv4 + IPv6) fronting the HTTPS load balancer ────────
resource "google_compute_global_address" "ipv4" {
  name       = "emisar-ipv4"
  ip_version = "IPV4"
  depends_on = [google_project_service.apis]
}

resource "google_compute_global_address" "ipv6" {
  name       = "emisar-ipv6"
  ip_version = "IPV6"
  depends_on = [google_project_service.apis]
}

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

# ── Backend: the MIG behind an HTTP backend service + health check ───────────
# Cloud CDN stays off (the console is authenticated + dynamic). Cloud Armor can
# attach here later via security_policy for WAF/rate-limiting.
resource "google_compute_backend_service" "app" {
  name                            = "emisar-backend"
  load_balancing_scheme           = "EXTERNAL_MANAGED"
  protocol                        = "HTTP"
  port_name                       = "http"
  timeout_sec                     = var.backend_timeout_sec
  connection_draining_timeout_sec = 120
  health_checks                   = [google_compute_health_check.app.id]

  # Structured request logging at the edge (SOC 2: access log / forensics).
  log_config {
    enable      = true
    sample_rate = 1.0
  }

  backend {
    group           = google_compute_region_instance_group_manager.emisar.instance_group
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }
}

# ── TLS policy: modern ciphers, TLS 1.2+ ─────────────────────────────────────
resource "google_compute_ssl_policy" "restricted" {
  name            = "emisar-ssl"
  profile         = "RESTRICTED"
  min_tls_version = "TLS_1_2"
}

# ── HTTPS front end ──────────────────────────────────────────────────────────
resource "google_compute_url_map" "https" {
  name            = "emisar-https"
  default_service = google_compute_backend_service.app.id
}

resource "google_compute_target_https_proxy" "https" {
  name            = "emisar-https-proxy"
  url_map         = google_compute_url_map.https.id
  certificate_map = "//certificatemanager.googleapis.com/${google_certificate_manager_certificate_map.emisar.id}"
  ssl_policy      = google_compute_ssl_policy.restricted.id
}

resource "google_compute_global_forwarding_rule" "https_v4" {
  name                  = "emisar-https-v4"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_address            = google_compute_global_address.ipv4.id
  port_range            = "443"
  target                = google_compute_target_https_proxy.https.id
}

resource "google_compute_global_forwarding_rule" "https_v6" {
  name                  = "emisar-https-v6"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_address            = google_compute_global_address.ipv6.id
  port_range            = "443"
  target                = google_compute_target_https_proxy.https.id
}

# ── HTTP → HTTPS redirect front end ──────────────────────────────────────────
resource "google_compute_url_map" "redirect" {
  name = "emisar-http-redirect"
  default_url_redirect {
    https_redirect         = true
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    strip_query            = false
  }
}

resource "google_compute_target_http_proxy" "redirect" {
  name    = "emisar-http-proxy"
  url_map = google_compute_url_map.redirect.id
}

resource "google_compute_global_forwarding_rule" "http_v4" {
  name                  = "emisar-http-v4"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_address            = google_compute_global_address.ipv4.id
  port_range            = "80"
  target                = google_compute_target_http_proxy.redirect.id
}

resource "google_compute_global_forwarding_rule" "http_v6" {
  name                  = "emisar-http-v6"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_address            = google_compute_global_address.ipv6.id
  port_range            = "80"
  target                = google_compute_target_http_proxy.redirect.id
}
