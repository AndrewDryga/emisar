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

  notification_channels = local.paging_notification_channels
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

resource "google_monitoring_alert_policy" "db_down" {
  display_name = "Emisar: Cloud SQL Instance Down"
  combiner     = "OR"

  documentation {
    content   = "The Emisar Cloud SQL instance is reporting that its server is not up. Inspect Cloud SQL operations, maintenance, and instance state before restarting or failing over the database."
    mime_type = "text/markdown"
  }

  user_labels = {
    component = "cloud-sql"
    signal    = "availability"
  }

  conditions {
    display_name = "Cloud SQL Server Up Below 1 for 5 Minutes"
    condition_threshold {
      filter          = "resource.type = \"cloudsql_database\" AND resource.labels.project_id = \"${var.project_id}\" AND resource.labels.database_id = \"${google_sql_database_instance.emisar.name}\" AND metric.type = \"cloudsql.googleapis.com/database/up\""
      comparison      = "COMPARISON_LT"
      threshold_value = 1
      duration        = "300s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = local.paging_notification_channels
}

# `google-monitoring-enabled` enables COS Node Problem Detector, whose guest
# metrics are reported against each VM. The portal-only instance label keeps
# these policies scoped to the MIG and excludes the optional Livebook VM.
resource "google_monitoring_alert_policy" "portal_cpu" {
  display_name = "Emisar: Portal VM CPU High"
  combiner     = "OR"

  documentation {
    content   = "Portal VM CPU utilization has remained above 85% for five minutes. Inspect the affected instance, application load, and most recent rollout before changing capacity."
    mime_type = "text/markdown"
  }

  user_labels = {
    component = "portal-vm"
    signal    = "cpu"
  }

  conditions {
    display_name = "Portal VM CPU Above 85% for 5 Minutes"
    condition_threshold {
      filter          = "resource.type = \"gce_instance\" AND metadata.user_labels.cluster_name = \"emisar\" AND metric.type = \"compute.googleapis.com/instance/cpu/utilization\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0.85
      duration        = "300s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = local.alert_notification_channels
}

resource "google_monitoring_alert_policy" "portal_memory" {
  display_name = "Emisar: Portal VM Memory High"
  combiner     = "OR"

  documentation {
    content   = "Portal VM memory utilization has remained above 90% for five minutes. Inspect the affected instance and application memory usage for a leak or undersized workload."
    mime_type = "text/markdown"
  }

  user_labels = {
    component = "portal-vm"
    signal    = "memory"
  }

  conditions {
    display_name = "Portal VM Memory Above 90% for 5 Minutes"
    condition_threshold {
      filter          = "resource.type = \"gce_instance\" AND metadata.user_labels.cluster_name = \"emisar\" AND metric.type = \"compute.googleapis.com/guest/memory/percent_used\" AND metric.labels.state = \"used\""
      comparison      = "COMPARISON_GT"
      threshold_value = 90
      duration        = "300s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = local.alert_notification_channels
}

resource "google_monitoring_alert_policy" "portal_disk" {
  display_name = "Emisar: Portal VM Disk Near Full"
  combiner     = "OR"

  documentation {
    content   = "Portal VM disk utilization has remained above 90% for five minutes. Inspect the affected device and release or container logs for unexpected disk growth before the VM reaches capacity."
    mime_type = "text/markdown"
  }

  user_labels = {
    component = "portal-vm"
    signal    = "disk"
  }

  conditions {
    display_name = "Portal VM Disk Above 90% for 5 Minutes"
    condition_threshold {
      filter          = "resource.type = \"gce_instance\" AND metadata.user_labels.cluster_name = \"emisar\" AND metric.type = \"compute.googleapis.com/guest/disk/percent_used\""
      comparison      = "COMPARISON_GT"
      threshold_value = 90
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

  notification_channels = local.paging_notification_channels
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

resource "google_monitoring_alert_policy" "lb_no_healthy_backends" {
  display_name = "Emisar: Load Balancer Zero Healthy Backends"
  combiner     = "OR"

  documentation {
    content   = "The portal backend is returning HTTP 503 responses through the global external Application Load Balancer for five minutes. Google documents 503 as the response when all backends are unhealthy; this is the closest native metric signal because Cloud Monitoring does not expose a clean healthy-backend-count metric for this load balancer. Confirm the incident with load-balancer logs and statusDetails=failed_to_pick_backend, since a backend-generated 503 can produce the same metric."
    mime_type = "text/markdown"
  }

  user_labels = {
    component = "load-balancer"
    signal    = "backend-health"
  }

  conditions {
    display_name = "Portal Backend HTTP 503 for 5 Minutes"
    condition_threshold {
      filter          = "resource.type = \"https_lb_rule\" AND resource.labels.backend_target_name = \"${google_compute_backend_service.app.name}\" AND metric.type = \"loadbalancing.googleapis.com/https/request_count\" AND metric.labels.response_code = 503"
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "300s"
      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_RATE"
        cross_series_reducer = "REDUCE_SUM"
      }
    }
  }

  notification_channels = local.paging_notification_channels
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

  notification_channels = local.paging_notification_channels
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

  notification_channels = local.paging_notification_channels
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

# ── Runner fleet health: dispatching to on-host runners is the product ───────
# /readyz (DB-aware) and lb_5xx never fire when the fleet strands: a WebSocket
# close is not a 5xx and the database stays up, so a control-plane socket
# regression or an LB backend-timeout change makes every run silently pile up.
# The portal's cluster-singleton emitter (Emisar.Runs.Jobs.FleetObservability)
# logs one `fleet.observability` line per minute — connected_runners and
# pending_dispatch_depth as JSON numbers — and these counter metrics + alerts
# watch it. Singleton emission means one series, so no per-VM double count.
resource "google_logging_metric" "fleet_no_connected_runners" {
  name        = "emisar/fleet_no_connected_runners"
  description = "Emitter ticks reporting zero connected runners fleet-wide (fleet.observability)."
  filter      = "resource.type=\"gce_instance\" AND jsonPayload.message=\"fleet.observability\" AND jsonPayload.connected_runners=0"

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }

  depends_on = [google_project_iam_member.terraform_apply_authority]
}

resource "google_logging_metric" "dispatch_backlog" {
  name        = "emisar/dispatch_backlog"
  description = "Emitter ticks whose pending-dispatch depth exceeds the backlog threshold (fleet.observability)."
  # The threshold lives in the filter (local.dispatch_backlog_alert_threshold),
  # so it is tuned by a terraform apply rather than a portal deploy.
  filter = "resource.type=\"gce_instance\" AND jsonPayload.message=\"fleet.observability\" AND jsonPayload.pending_dispatch_depth>${local.dispatch_backlog_alert_threshold}"

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }

  depends_on = [google_project_iam_member.terraform_apply_authority]
}

resource "google_monitoring_alert_policy" "fleet_no_connected_runners" {
  display_name = "Emisar: Runner Fleet Offline"
  combiner     = "OR"

  documentation {
    content   = "Every runner is disconnected fleet-wide while the site stays up, so all dispatches are stranded and no customer action can execute. /readyz and lb_5xx do not catch this (a WebSocket close is not a 5xx and the database is healthy). Check for a recent portal deploy or an LB backend-timeout change, the runner WebSocket ingress path, and whether runners are reconnecting; the emisar.runners.connection.* gauges and the runner audit trail carry per-account detail."
    mime_type = "text/markdown"
  }

  user_labels = {
    component = "runner-fleet"
    signal    = "availability"
  }

  conditions {
    display_name = "Zero connected runners fleet-wide for 5 minutes"
    condition_threshold {
      filter          = "resource.type = \"gce_instance\" AND metric.type = \"logging.googleapis.com/user/${google_logging_metric.fleet_no_connected_runners.name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "300s"
      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
      }
    }
  }

  notification_channels = local.paging_notification_channels
}

resource "google_monitoring_alert_policy" "dispatch_backlog" {
  display_name = "Emisar: Dispatch Backlog"
  combiner     = "OR"

  documentation {
    content   = "The pending-dispatch backlog (runs awaiting a runner) has stayed above the threshold, so action runs are queuing faster than the fleet drains them — usually no eligible or connected runner for the targeted scope, or a dispatch regression. Check connected runners for the affected scope, the DispatchTimeout sweep, and recent policy or runner-scope changes. The threshold is local.dispatch_backlog_alert_threshold in monitoring.tf."
    mime_type = "text/markdown"
  }

  user_labels = {
    component = "dispatch-queue"
    signal    = "saturation"
  }

  conditions {
    display_name = "Pending dispatch backlog above threshold for 10 minutes"
    condition_threshold {
      filter          = "resource.type = \"gce_instance\" AND metric.type = \"logging.googleapis.com/user/${google_logging_metric.dispatch_backlog.name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "600s"
      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
      }
    }
  }

  notification_channels = local.paging_notification_channels
}
