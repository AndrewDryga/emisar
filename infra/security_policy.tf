# Edge rate limiting.
#
# Before this, the only rate limit was application-level: every abusive request
# cost a BEAM process and a database round trip before anything said no. Cloud
# Armor answers at the edge, and this policy is shared by the portal and Livebook
# backends (load_balancer.tf).
#
# The per-IP ceiling enforces (deny 429 + ban) at a deliberately generous
# threshold. Generous ON PURPOSE: the legitimate high-rate clients — an MCP
# client polling `wait_for_run`, a fleet of runners reconnecting after a rollout
# behind one NAT, a CI job dispatching a batch — must not be dropped, while
# volumetric abuse from a single source still gets banned. Tighten from the
# request logs; lowering the threshold is a one-line change and its own reviewed
# apply.

resource "google_compute_security_policy" "app" {
  name        = "emisar-app"
  description = "Edge per-IP rate limiting for the load balancer backends."

  # Per-IP request ceiling, enforcing. 600/min (10 req/s) bans volumetric abuse
  # from a single source without stranding a legitimate poller, a post-rollout
  # runner reconnect storm behind one NAT, or a CI batch. Tighten from the
  # request logs if abuse warrants it.
  rule {
    action   = "rate_based_ban"
    priority = 1000

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
