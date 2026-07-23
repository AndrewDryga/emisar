# ── Monitoring & alerting (SOC 2 CC7: detect availability + integrity issues) ─
# Every alert emails the on-call address and, when configured, posts to a Slack
# channel for at-a-glance visibility. The severe, silent-failure subset ALSO
# pages the Better Stack on-call rotation via the Google Monitoring integration
# (uptime.tf): those signals have no external symptom until they are already a
# customer-visible outage, so an inbox is not enough.
resource "google_monitoring_notification_channel" "email" {
  display_name = "Emisar: On-Call Email"
  type         = "email"
  labels = {
    email_address = var.alert_email
  }
  depends_on = [google_project_service.apis]
}

# The webhook the Better Stack Google Monitoring integration (uptime.tf)
# generates. Its URL embeds a secret token and is a computed attribute, so it
# never lands in committed config. Gated with the integration on the paid tier
# (var.betterstack_gcp_paging); GCP does not verify webhook reachability at apply
# time — a bad token surfaces on a test notification, not the plan.
resource "google_monitoring_notification_channel" "betterstack" {
  count = var.betterstack_gcp_paging ? 1 : 0

  display_name = "Emisar: Better Stack On-Call"
  type         = "webhook_tokenauth"
  labels = {
    url = betteruptime_google_monitoring_integration.internal[0].webhook_url
  }
  depends_on = [google_project_service.apis]
}

locals {
  # A Slack channel is created in the console (a GCP Slack channel holds an OAuth
  # token Terraform can't round-trip) and referenced by ID; empty => email only.
  slack_alert_channels = var.slack_alert_channel_id == "" ? [] : [var.slack_alert_channel_id]

  # Every alert: email + optional Slack.
  alert_notification_channels = concat(
    [google_monitoring_notification_channel.email.id],
    local.slack_alert_channels,
  )

  # The severe, silent-failure subset (Cloud SQL down / near-full / txid-
  # wraparound, zero healthy backends, MIG below target, NAT allocation failure)
  # also pages Better Stack — but only when the paid integration is enabled. The
  # splat is [] while var.betterstack_gcp_paging is off, so these fall back to
  # email + Slack and the config applies cleanly on the free tier.
  paging_notification_channels = concat(
    local.alert_notification_channels,
    google_monitoring_notification_channel.betterstack[*].id,
  )

  # Sustained pending-dispatch depth (runs awaiting a runner) above this is a
  # backlog worth paging on — dispatches piling up with no eligible runner. Tuned
  # here with a terraform apply, not baked into the portal image.
  dispatch_backlog_alert_threshold = 25
}

