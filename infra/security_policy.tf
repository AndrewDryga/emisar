# Edge rate limiting, in PREVIEW.
#
# Before this, the only rate limit was application-level: every abusive request
# cost a BEAM process and a database round trip before anything said no. Cloud
# Armor answers at the edge.
#
# Every rule ships with `preview = true` ON PURPOSE. A rate limit tuned by
# guessing is a rate limit that drops real operators — an MCP client polling
# `wait_for_run`, a fleet of runners reconnecting after a rollout, a CI job
# dispatching a batch. Preview logs what WOULD have been blocked without
# blocking it, so the thresholds get set from this deployment's own traffic.
# Flipping a rule to enforcing is a one-line change and its own reviewed apply.

resource "google_compute_security_policy" "app" {
  name        = "emisar-app"
  description = "Edge rate limiting for the portal backend. Rules are in preview until tuned against real traffic."

  # Per-IP request ceiling. The threshold is deliberately generous: the point of
  # the first pass is to find out where legitimate traffic actually sits, and a
  # rule that never fires in preview teaches nothing.
  rule {
    action   = "rate_based_ban"
    priority = 1000
    preview  = true

    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }

    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"

      enforce_on_key = "IP"

      rate_limit_threshold {
        count        = 600
        interval_sec = 60
      }

      # A banned source stays banned for long enough to matter but not long
      # enough to strand an operator behind a shared NAT for an afternoon.
      ban_duration_sec = 300
    }

    description = "Per-IP request ceiling"
  }

  rule {
    action   = "allow"
    priority = 2147483647

    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }

    description = "Default allow"
  }

  depends_on = [google_project_service.apis]
}
