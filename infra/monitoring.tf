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
