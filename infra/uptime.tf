# ── External uptime, on-call & status page (Better Stack) — SOC 2 CC7 ────────
# Google's uptime check (monitoring.tf) shares a failure domain with everything
# it watches: an incident in the serving cloud can take out the site AND the
# alert path in one stroke. Better Stack probes from independent infrastructure,
# runs the on-call escalation, and hosts the public status page — so detection,
# paging, and customer communication all survive the outage they report on. It
# monitors the public hostname rather than a provider-internal endpoint.
#
# The account predates this config, so the pre-existing resources are adopted
# via import blocks (no-ops after the first apply) instead of being recreated —
# recreating them would discard the status page's uptime history.

provider "betteruptime" {
  api_token = var.betterstack_api_token
}

import {
  to = betteruptime_on_call_calendar.primary
  id = "391634"
}

import {
  to = betteruptime_monitor.portal
  id = "4499550"
}

import {
  to = betteruptime_status_page.emisar
  id = "250271"
}

import {
  to = betteruptime_status_page_section.control_plane
  id = "250271/330559"
}

import {
  to = betteruptime_status_page_resource.portal
  id = "250271/8901315"
}

# ── On-call & escalation ──────────────────────────────────────────────────────
# The roster lives in var.oncall_emails (a SENSITIVE workspace variable), so the
# public repo reveals neither who is on call nor how many people that is — the
# same reason there is no betteruptime_team_member resource here: one resource
# instance per person would put the headcount in the plan. People are invited
# to Better Stack out of band; the rotation references them by account email.
resource "betteruptime_on_call_calendar" "primary" {
  name = "Primary on-call schedule"

  on_call_rotation {
    users             = var.oncall_emails
    rotation_interval = "week"
    rotation_length   = 1

    # Fixed anchors on purpose: timestamp() would re-anchor the rotation every
    # apply. Monday-start weeks; the far end is "until we change this config".
    start_rotations_at = "2026-07-13T00:00:00Z"
    end_rotations_at   = "2036-07-13T00:00:00Z"
  }
}

# Two urgencies: a polite nudge, then one that cuts through Do-Not-Disturb.
resource "betteruptime_severity" "notify" {
  name = "Notify on-call"

  email = true
  push  = true

  critical_alert = false
  call           = false
  sms            = false
}

resource "betteruptime_severity" "wake" {
  name = "Wake on-call"

  critical_alert = true
  call           = true
  sms            = true

  email = false
  push  = false
}

# Escalation: notify the on-call immediately; if unacknowledged, call them at
# 3 minutes; at 10 minutes call EVERYONE. Repeats 3× so a missed first wave
# does not end the paging.
resource "betteruptime_policy" "incident" {
  name = "emisar service down"

  steps {
    type        = "escalation"
    wait_before = 0
    urgency_id  = betteruptime_severity.notify.id

    step_members {
      type = "current_on_call"
    }
  }

  steps {
    type        = "escalation"
    wait_before = 3 * 60
    urgency_id  = betteruptime_severity.wake.id

    step_members {
      type = "current_on_call"
    }
  }

  steps {
    type        = "escalation"
    wait_before = 7 * 60
    urgency_id  = betteruptime_severity.wake.id

    step_members {
      type = "entire_team"
    }
  }

  repeat_count = 3
  repeat_delay = 5 * 60
}

# ── Monitors ──────────────────────────────────────────────────────────────────
# /readyz is DB-aware, so "up" attests the web tier AND its database — the same
# contract the LB uses (compute.tf), verified from outside. Imported from the
# manually-created apex monitor to keep its uptime history; the config moves it
# from / to /readyz and attaches the escalation policy.
resource "betteruptime_monitor" "portal" {
  url          = "https://${var.domain}/readyz"
  monitor_type = "status"

  pronounceable_name = "emisar portal"

  policy_id = betteruptime_policy.incident.id

  follow_redirects = false
  remember_cookies = false
  verify_ssl       = true

  # Independent of the GCP-side cert-renewal alert (monitoring.tf): these watch
  # expiry on whatever is actually serving the domain, from outside.
  ssl_expiration    = 7
  domain_expiration = 14
}

# The unauthenticated `emisar pack install` path.
resource "betteruptime_monitor" "pack_registry" {
  url          = "https://registry.${var.domain}/v1/catalog.json"
  monitor_type = "status"

  pronounceable_name = "emisar pack registry"

  policy_id = betteruptime_policy.incident.id

  follow_redirects = false
  remember_cookies = false
  verify_ssl       = true

  ssl_expiration    = 7
  domain_expiration = 14
}

# ── Public status page ────────────────────────────────────────────────────────
# status.<domain> CNAMEs to Better Stack in dns.tf (resolving since the zone
# went authoritative), and var.caa_issuers already allows Let's Encrypt for it;
# the page also serves at https://emisar.betteruptime.com.
resource "betteruptime_status_page" "emisar" {
  company_name = "Emisar"
  company_url  = "https://${var.domain}"
  contact_url  = "mailto:support@${var.domain}"

  # The logo pair uploaded to Better Stack's CDN from the account (a page-level
  # asset, not a secret); dark_logo_url serves visitors in dark mode.
  logo_url      = "https://d1lppblt9t2x15.cloudfront.net/logos/1d18b688f85b4624a44534cd4c7b2110.png"
  dark_logo_url = "https://d1lppblt9t2x15.cloudfront.net/logos/dc8aa6774ce3e880b99263776c9dad28.png"

  # UTC on purpose: operators are global, and a locale here would leak into the
  # public repo (house rule — no personal/locale tells in committed values).
  timezone = "UTC"

  subdomain     = "emisar"
  custom_domain = "status.${var.domain}"

  # Reports are generated automatically when a monitor goes down —
  # communication starts even before a human picks up the incident.
  # (`subscribable` is deliberately absent: subscription settings are gated to
  # a paid Better Stack tier — the API 403s on it — so it stays at the account
  # default until the plan supports it.)
  automatic_reports = true

  # Show a full quarter of history; hide sub-minute blips (a flapping check is
  # an alerting concern, not a customer communication).
  history             = 90
  min_incident_length = 60

  hide_from_search_engines = false

  design = "v2"
  theme  = "light"
  layout = "vertical"
}

resource "betteruptime_status_page_section" "control_plane" {
  status_page_id = betteruptime_status_page.emisar.id
  name           = "Control plane"
  position       = 0
}

resource "betteruptime_status_page_resource" "portal" {
  status_page_id         = betteruptime_status_page.emisar.id
  status_page_section_id = betteruptime_status_page_section.control_plane.id

  public_name = "Portal, console & MCP API"
  explanation = "The emisar web console, API, and MCP endpoint at ${var.domain}."

  resource_type = "Monitor"
  resource_id   = betteruptime_monitor.portal.id

  widget_type = "history"
}

resource "betteruptime_status_page_section" "distribution" {
  status_page_id = betteruptime_status_page.emisar.id
  name           = "Distribution"
  position       = 1
}

resource "betteruptime_status_page_resource" "pack_registry" {
  status_page_id         = betteruptime_status_page.emisar.id
  status_page_section_id = betteruptime_status_page_section.distribution.id

  public_name = "Pack registry"
  explanation = "Serves the public action-pack catalog and tarballs for `emisar pack install` at registry.${var.domain}."

  resource_type = "Monitor"
  resource_id   = betteruptime_monitor.pack_registry.id

  widget_type = "history"
}
