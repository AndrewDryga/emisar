# ── Monitoring & alerting (SOC 2 CC7: detect availability + integrity issues) ─
# A single email notification channel + a few high-signal alert policies. Add
# more channels (PagerDuty, Slack) by extending var.alert_email into a list later.
resource "google_monitoring_notification_channel" "email" {
  display_name = "emisar on-call email"
  type         = "email"
  labels = {
    email_address = var.alert_email
  }
  depends_on = [google_project_service.apis]
}

# External uptime check on the public URL — proves the site is reachable + serving.
resource "google_monitoring_uptime_check_config" "https" {
  display_name = "emisar https"
  timeout      = "10s"
  period       = "60s"

  http_check {
    path         = "/healthz"
    port         = 443
    use_ssl      = true
    validate_ssl = true
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project_id
      host       = var.domain
    }
  }

  depends_on = [google_project_service.apis]
}

resource "google_monitoring_alert_policy" "uptime" {
  display_name = "emisar unreachable (uptime check failing)"
  combiner     = "OR"

  conditions {
    display_name = "uptime check failed"
    condition_threshold {
      filter          = "resource.type = \"uptime_url\" AND metric.type = \"monitoring.googleapis.com/uptime_check/check_passed\" AND metric.label.check_id = \"${google_monitoring_uptime_check_config.https.uptime_check_id}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 1
      duration        = "300s"

      aggregations {
        alignment_period     = "1200s"
        per_series_aligner   = "ALIGN_NEXT_OLDER"
        cross_series_reducer = "REDUCE_COUNT_FALSE"
        group_by_fields      = ["resource.label.host"]
      }
      trigger {
        count = 1
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]
}

resource "google_monitoring_alert_policy" "db_cpu" {
  display_name = "emisar Cloud SQL CPU high"
  combiner     = "OR"

  conditions {
    display_name = "CPU > 90% for 5m"
    condition_threshold {
      filter          = "resource.type = \"cloudsql_database\" AND metric.type = \"cloudsql.googleapis.com/database/cpu/utilization\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0.9
      duration        = "300s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]
}

resource "google_monitoring_alert_policy" "db_disk" {
  display_name = "emisar Cloud SQL disk near full"
  combiner     = "OR"

  conditions {
    display_name = "disk > 90% for 5m"
    condition_threshold {
      filter          = "resource.type = \"cloudsql_database\" AND metric.type = \"cloudsql.googleapis.com/database/disk/utilization\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0.9
      duration        = "300s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]
}
