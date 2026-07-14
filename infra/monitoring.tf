# ── Monitoring & alerting (SOC 2 CC7: detect availability + integrity issues) ─
# A single email notification channel + a few high-signal alert policies. Add
# more channels (PagerDuty, Slack) by extending var.alert_email into a list later.
resource "google_monitoring_notification_channel" "email" {
  display_name = "Emisar: On-Call Email"
  type         = "email"
  labels = {
    email_address = var.alert_email
  }
  depends_on = [google_project_service.apis]
}

# Better Stack's Google Monitoring webhook requires a paid integration. Keep
# native GCP alerts on the included email path; Better Stack still owns and
# pages for its external portal and registry monitors in uptime.tf.
locals {
  alert_notification_channels = [google_monitoring_notification_channel.email.id]
}

# External readiness check proves the site and its database are serving.
resource "google_monitoring_uptime_check_config" "https" {
  display_name = "Emisar: Control Plane Readiness"
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

resource "google_monitoring_uptime_check_config" "pack_registry_semantic" {
  display_name = "Emisar: Pack Registry Catalog Semantics"
  timeout      = "10s"
  period       = "300s"

  http_check {
    path         = "/v1/catalog.json"
    port         = 443
    use_ssl      = true
    validate_ssl = true
  }

  content_matchers {
    content = "1"
    matcher = "MATCHES_JSON_PATH"

    json_path_matcher {
      json_path    = "$.schema_version"
      json_matcher = "EXACT_MATCH"
    }
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project_id
      host       = "registry.${var.domain}"
    }
  }

  depends_on = [google_project_service.apis]
}

resource "google_monitoring_alert_policy" "uptime" {
  display_name = "Emisar: Control Plane Unreachable"
  combiner     = "OR"

  conditions {
    display_name = "Uptime Check Failed"
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

  notification_channels = local.alert_notification_channels
}

resource "google_monitoring_alert_policy" "pack_registry_checks" {
  display_name = "Emisar: Pack Registry Integrity Check Failed"
  combiner     = "OR"

  dynamic "conditions" {
    for_each = {
      semantic = google_monitoring_uptime_check_config.pack_registry_semantic.uptime_check_id
    }
    content {
      display_name = "${title(conditions.key)} check failed"
      condition_threshold {
        filter          = "resource.type = \"uptime_url\" AND metric.type = \"monitoring.googleapis.com/uptime_check/check_passed\" AND metric.label.check_id = \"${conditions.value}\""
        comparison      = "COMPARISON_GT"
        threshold_value = 1
        duration        = "600s"

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
  }

  notification_channels = local.alert_notification_channels
}

resource "google_monitoring_alert_policy" "db_cpu" {
  display_name = "Emisar: Cloud SQL CPU High"
  combiner     = "OR"

  conditions {
    display_name = "CPU Above 90% for 5 Minutes"
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

  notification_channels = local.alert_notification_channels
}

resource "google_monitoring_alert_policy" "db_disk" {
  display_name = "Emisar: Cloud SQL Disk Near Full"
  combiner     = "OR"

  conditions {
    display_name = "Disk Above 90% for 5 Minutes"
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

  notification_channels = local.alert_notification_channels
}

resource "google_monitoring_alert_policy" "db_memory" {
  display_name = "Emisar: Cloud SQL Memory High"
  combiner     = "OR"

  conditions {
    display_name = "Memory Above 90% for 5 Minutes"
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

  notification_channels = local.alert_notification_channels
}

# Transaction-ID wraparound is the one Postgres failure mode that gives no
# user-visible symptom until the database force-stops writes — autovacuum
# normally keeps it near zero, so a climb past 70% means vacuum is stuck
# (long-lived transaction, abandoned replication slot) and needs a human
# well before the 100% hard stop.
resource "google_monitoring_alert_policy" "db_txid" {
  display_name = "Emisar: Cloud SQL Transaction ID Wraparound Risk"
  combiner     = "OR"

  conditions {
    display_name = "Transaction ID Utilization Above 70% for 15 Minutes"
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

  notification_channels = local.alert_notification_channels
}

# Users seeing errors while the readiness check still passes — a sustained 5xx
# ratio at the LB is the signal
# that real traffic is failing. Ratio, not count, so it doesn't scale with
# traffic volume.
resource "google_monitoring_alert_policy" "lb_5xx" {
  display_name = "Emisar: Load Balancer 5xx Ratio High"
  combiner     = "OR"

  conditions {
    display_name = "5xx Responses Above 5% for 5 Minutes"
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

  notification_channels = local.alert_notification_channels
}

# The managed certs auto-renew, so a shrinking expiry window means renewal is
# FAILING (DNS auth broken, CAA blocking issuance) — two weeks is enough
# runway to fix it before browsers hard-fail. Measured by the uptime check
# (validate_ssl above), so it watches the cert actually served, not the one
# Certificate Manager thinks it provisioned.
resource "google_monitoring_alert_policy" "cert_expiry" {
  display_name = "Emisar: TLS Certificate Expiring"
  combiner     = "OR"

  conditions {
    display_name = "Served Certificate Expires Within 14 Days"
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

  notification_channels = local.alert_notification_channels
}

# The zero-unavailable rollout should never put the MIG below target. Remaining
# below target for 15m means repair or creation is genuinely stuck.
resource "google_monitoring_alert_policy" "mig_below_target" {
  display_name = "Emisar: Instance Group Below Target"
  combiner     = "OR"

  conditions {
    display_name = "Running Instances Below Target for 15 Minutes"
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

  notification_channels = local.alert_notification_channels
}

# NAT port exhaustion silently breaks all egress (GHCR pulls on boot, Postmark,
# Paddle, Sentry) while ingress keeps working — nothing else surfaces it until
# a rollout can't pull the image or emails stop sending.
resource "google_monitoring_alert_policy" "nat_allocation" {
  display_name = "Emisar: Cloud NAT Allocation Failure"
  combiner     = "OR"

  conditions {
    display_name = "NAT Port Allocation Failures"
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

  notification_channels = local.alert_notification_channels
}

resource "google_logging_metric" "recurrent_job_failures" {
  name        = "emisar/recurrent_job_failures"
  description = "Crashes at the shared supervised recurrent-job executor boundary."
  filter      = "resource.type=\"gce_instance\" AND jsonPayload.message=\"recurrent_job.failed\""

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }

  depends_on = [google_project_iam_member.terraform_apply_authority]
}

resource "google_logging_metric" "billing_sync_failures" {
  name        = "emisar/billing_sync_failures"
  description = "Paddle subscription retrieval or persistence failures."
  filter      = "resource.type=\"gce_instance\" AND (jsonPayload.message=\"billing_sync.retrieve_failed\" OR jsonPayload.message=\"billing_sync.upsert_failed\")"

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }

  depends_on = [google_project_iam_member.terraform_apply_authority]
}

resource "google_logging_metric" "cluster_failures" {
  name        = "emisar/cluster_failures"
  description = "Final GCE discovery errors or repeated BEAM distribution connection failures."
  filter      = "resource.type=\"gce_instance\" AND ((severity>=ERROR AND jsonPayload.message:\"cluster discovery failed\") OR jsonPayload.message:\"cluster: can't connect\")"

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }

  depends_on = [google_project_iam_member.terraform_apply_authority]
}

resource "google_monitoring_alert_policy" "recurrent_job_failures" {
  display_name = "Emisar: Recurrent Job Failed"
  combiner     = "OR"

  conditions {
    display_name = "Any recurrent job crash in 5 minutes"
    condition_threshold {
      filter          = "resource.type = \"gce_instance\" AND metric.type = \"logging.googleapis.com/user/${google_logging_metric.recurrent_job_failures.name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"
      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
      }
    }
  }

  notification_channels = local.alert_notification_channels
}

resource "google_monitoring_alert_policy" "billing_sync_failures" {
  display_name = "Emisar: Paddle Reconciliation Failed"
  combiner     = "OR"

  conditions {
    display_name = "Any Paddle reconciliation failure in 5 minutes"
    condition_threshold {
      filter          = "resource.type = \"gce_instance\" AND metric.type = \"logging.googleapis.com/user/${google_logging_metric.billing_sync_failures.name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"
      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
      }
    }
  }

  notification_channels = local.alert_notification_channels
}

resource "google_monitoring_alert_policy" "cluster_failures" {
  display_name = "Emisar: Application Cluster Formation Failed"
  combiner     = "OR"

  conditions {
    display_name = "Persistent peer discovery or distribution failures in 5 minutes"
    condition_threshold {
      filter          = "resource.type = \"gce_instance\" AND metric.type = \"logging.googleapis.com/user/${google_logging_metric.cluster_failures.name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "300s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = local.alert_notification_channels
}
