# ── Monitoring & alerting (SOC 2 CC7: detect availability + integrity issues) ─
# Every alert emails the on-call address and, when configured, posts to a Slack
# channel for at-a-glance visibility. The severe, silent-failure subset ALSO
# pages the Better Stack on-call rotation via the Google Monitoring integration
# (betterstack.tf): those signals have no external symptom until they are already a
# customer-visible outage, so an inbox is not enough.
resource "google_monitoring_notification_channel" "email" {
  display_name = "Emisar: On-Call Email"
  type         = "email"
  labels = {
    email_address = var.alert_email
  }
  depends_on = [google_project_service.apis]
}

# The webhook the Better Stack Google Monitoring integration (betterstack.tf)
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
