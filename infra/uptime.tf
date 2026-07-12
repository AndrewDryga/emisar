# ── External uptime + status page (Better Stack) — SOC 2 CC7 ─────────────────
# Google's uptime check (monitoring.tf) shares a failure domain with everything
# it watches: an incident in the serving cloud can take out the site AND the
# alert path in one stroke. Better Stack probes from independent infrastructure
# and hosts the public status page, so detection and customer communication
# both survive the outage they report on. It also monitors the PUBLIC hostname,
# which means it watches the Fly deployment today and follows traffic to GCP at
# cutover with no change here.

provider "betteruptime" {
  api_token = var.betterstack_api_token
}

# /readyz is DB-aware, so "up" attests the web tier AND its database — the same
# contract the LB uses (compute.tf), verified from outside.
resource "betteruptime_monitor" "portal" {
  url          = "https://${var.domain}/readyz"
  monitor_type = "status"

  pronounceable_name = "emisar portal"

  follow_redirects = false
  remember_cookies = false
  verify_ssl       = true

  # The GCP-side cert-renewal alert (monitoring.tf) only observes traffic after
  # cutover; these watch expiry on whatever is actually serving the domain.
  ssl_expiration    = 7
  domain_expiration = 14

  # Solo-operator alerting: email + mobile push, no call/SMS chain. When there
  # is an on-call rotation, replace these with a betteruptime_policy escalation.
  email = true
  push  = true
  call  = false
  sms   = false
}

# The unauthenticated `emisar pack install` path. Paused until
# registry.<domain> resolves publicly (README cutover runbook — the registry
# can go live independently, before any traffic move); unpause it then, or the
# monitor pages about DNS that is intentionally not delegated yet.
resource "betteruptime_monitor" "pack_registry" {
  url          = "https://registry.${var.domain}/v1/catalog.json"
  monitor_type = "status"

  pronounceable_name = "emisar pack registry"

  paused = true

  follow_redirects = false
  remember_cookies = false
  verify_ssl       = true

  ssl_expiration    = 7
  domain_expiration = 14

  email = true
  push  = true
  call  = false
  sms   = false
}

# ── Public status page ────────────────────────────────────────────────────────
# status.<domain> CNAMEs to Better Stack in dns.tf, and var.caa_issuers already
# allows Let's Encrypt for it. The custom domain activates once the zone is
# authoritative (or earlier via the same CNAME at the current registrar); until
# then the page serves at https://<subdomain>.betteruptime.com.
resource "betteruptime_status_page" "emisar" {
  company_name = "emisar"
  company_url  = "https://${var.domain}"

  timezone = "UTC"

  subdomain     = "emisar"
  custom_domain = "status.${var.domain}"

  design = "v2"
  theme  = "light"
  layout = "vertical"
}

resource "betteruptime_status_page_section" "control_plane" {
  status_page_id = betteruptime_status_page.emisar.id
  name           = "Control plane"
}

resource "betteruptime_status_page_resource" "portal" {
  status_page_id         = betteruptime_status_page.emisar.id
  status_page_section_id = betteruptime_status_page_section.control_plane.id

  public_name = "Portal, console & MCP API"

  resource_type = "Monitor"
  resource_id   = betteruptime_monitor.portal.id
}

resource "betteruptime_status_page_section" "distribution" {
  status_page_id = betteruptime_status_page.emisar.id
  name           = "Distribution"
}

resource "betteruptime_status_page_resource" "pack_registry" {
  status_page_id         = betteruptime_status_page.emisar.id
  status_page_section_id = betteruptime_status_page_section.distribution.id

  public_name = "Pack registry"

  resource_type = "Monitor"
  resource_id   = betteruptime_monitor.pack_registry.id
}
