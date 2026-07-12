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

# External readiness check proves the site and its database are serving.
resource "google_monitoring_uptime_check_config" "https" {
  display_name = "emisar https"
  timeout      = "10s"
  period       = "60s"

  http_check {
    path         = "/readyz"
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

resource "google_monitoring_alert_policy" "db_memory" {
  display_name = "emisar Cloud SQL memory high"
  combiner     = "OR"

  conditions {
    display_name = "memory > 90% for 5m"
    condition_threshold {
      filter          = "resource.type = \"cloudsql_database\" AND metric.type = \"cloudsql.googleapis.com/database/memory/utilization\""
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

# Transaction-ID wraparound is the one Postgres failure mode that gives no
# user-visible symptom until the database force-stops writes — autovacuum
# normally keeps it near zero, so a climb past 70% means vacuum is stuck
# (long-lived transaction, abandoned replication slot) and needs a human
# well before the 100% hard stop.
resource "google_monitoring_alert_policy" "db_txid" {
  display_name = "emisar Cloud SQL transaction-ID wraparound risk"
  combiner     = "OR"

  conditions {
    display_name = "txid utilization > 70% for 15m"
    condition_threshold {
      filter          = "resource.type = \"cloudsql_database\" AND metric.type = \"cloudsql.googleapis.com/database/postgresql/transaction_id_utilization\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0.7
      duration        = "900s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]
}

# Users seeing errors while the readiness check still passes — a sustained 5xx
# ratio at the LB is the signal
# that real traffic is failing. Ratio, not count, so it doesn't scale with
# traffic volume.
resource "google_monitoring_alert_policy" "lb_5xx" {
  display_name = "emisar LB 5xx ratio high"
  combiner     = "OR"

  conditions {
    display_name = "5xx > 5% of requests for 5m"
    condition_threshold {
      filter             = "resource.type = \"https_lb_rule\" AND metric.type = \"loadbalancing.googleapis.com/https/request_count\" AND metric.labels.response_code_class = 500"
      denominator_filter = "resource.type = \"https_lb_rule\" AND metric.type = \"loadbalancing.googleapis.com/https/request_count\""
      comparison         = "COMPARISON_GT"
      threshold_value    = 0.05
      duration           = "300s"
      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_RATE"
        cross_series_reducer = "REDUCE_SUM"
      }
      denominator_aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_RATE"
        cross_series_reducer = "REDUCE_SUM"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]
}

# The managed certs auto-renew, so a shrinking expiry window means renewal is
# FAILING (DNS auth broken, CAA blocking issuance) — two weeks is enough
# runway to fix it before browsers hard-fail. Measured by the uptime check
# (validate_ssl above), so it watches the cert actually served, not the one
# Certificate Manager thinks it provisioned.
resource "google_monitoring_alert_policy" "cert_expiry" {
  display_name = "emisar TLS certificate expiring (renewal failing)"
  combiner     = "OR"

  conditions {
    display_name = "served cert expires in < 14 days"
    condition_threshold {
      filter          = "resource.type = \"uptime_url\" AND metric.type = \"monitoring.googleapis.com/uptime_check/time_until_ssl_cert_expires\" AND metric.label.check_id = \"${google_monitoring_uptime_check_config.https.uptime_check_id}\""
      comparison      = "COMPARISON_LT"
      threshold_value = 14
      duration        = "600s"
      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_MIN"
        cross_series_reducer = "REDUCE_MIN"
        group_by_fields      = ["resource.label.host"]
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]
}

# The zero-unavailable rollout should never put the MIG below target. Remaining
# below target for 15m means repair or creation is genuinely stuck.
resource "google_monitoring_alert_policy" "mig_below_target" {
  display_name = "emisar instance group below target size"
  combiner     = "OR"

  conditions {
    display_name = "running instances < target for 15m"
    condition_threshold {
      filter          = "resource.type = \"instance_group\" AND resource.labels.instance_group_name = \"${google_compute_region_instance_group_manager.emisar.name}\" AND metric.type = \"compute.googleapis.com/instance_group/size\""
      comparison      = "COMPARISON_LT"
      threshold_value = var.instance_count
      duration        = "900s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]
}

# NAT port exhaustion silently breaks all egress (GHCR pulls on boot, Postmark,
# Paddle, Sentry) while ingress keeps working — nothing else surfaces it until
# a rollout can't pull the image or emails stop sending.
resource "google_monitoring_alert_policy" "nat_allocation" {
  display_name = "emisar Cloud NAT allocation failing"
  combiner     = "OR"

  conditions {
    display_name = "NAT port allocation failures"
    condition_threshold {
      filter          = "resource.type = \"nat_gateway\" AND metric.type = \"router.googleapis.com/nat/nat_allocation_failed\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "300s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_COUNT_TRUE"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]
}
