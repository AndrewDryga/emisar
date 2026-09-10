# The counter metrics the alert policies below evaluate. Every one is a DELTA
# INT64 count of matching log lines, so only the name, the sentence, and the
# filter differ; `emisar/<key>` is the live metric name in Cloud Monitoring and
# renaming a key renames the metric.
locals {
  application_log_metrics = {
    recurrent_job_failures = {
      description = "Crashes at the shared supervised recurrent-job executor boundary."
      filter      = "resource.type=\"gce_instance\" AND jsonPayload.message=\"recurrent_job.failed\""
    }

    billing_sync_failures = {
      description = "Paddle lifecycle or billable-runner quantity reconciliation failures."
      filter      = "resource.type=\"gce_instance\" AND (jsonPayload.message=\"billing_sync.retrieve_failed\" OR jsonPayload.message=\"billing_sync.upsert_failed\" OR jsonPayload.message=\"billing_sync.runner_quantity_failed\" OR jsonPayload.message=\"billing_runner_quantity_sync.failed\" OR jsonPayload.message=\"billing_runner_quantity_sync.crashed\")"
    }

    cluster_failures = {
      description = "Final GCE discovery errors or repeated BEAM distribution connection failures."
      filter      = "resource.type=\"gce_instance\" AND ((severity>=ERROR AND jsonPayload.message:\"cluster discovery failed\") OR jsonPayload.message:\"cluster: can't connect\")"
    }

    fleet_observability_ticks = {
      description = "Every fleet.observability emitter tick, regardless of runner or backlog values."
      filter      = "resource.type=\"gce_instance\" AND jsonPayload.message=\"fleet.observability\""
    }

    fleet_no_connected_runners = {
      description = "Emitter ticks reporting zero connected runners fleet-wide (fleet.observability)."
      filter      = "resource.type=\"gce_instance\" AND jsonPayload.message=\"fleet.observability\" AND jsonPayload.connected_runners=0"
    }

    # The backlog threshold lives in the filter, so it is tuned by a terraform
    # apply rather than a portal deploy.
    dispatch_backlog = {
      description = "Emitter ticks whose pending-dispatch depth exceeds the backlog threshold (fleet.observability)."
      filter      = "resource.type=\"gce_instance\" AND jsonPayload.message=\"fleet.observability\" AND jsonPayload.pending_dispatch_depth>${local.dispatch_backlog_alert_threshold}"
    }
  }
}

resource "google_logging_metric" "application" {
  for_each = local.application_log_metrics

  name        = "emisar/${each.key}"
  description = each.value.description
  filter      = each.value.filter

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }

  depends_on = [
    google_project_service.apis,
    google_project_iam_member.terraform_apply_authority,
  ]
}

resource "google_monitoring_alert_policy" "recurrent_job_failures" {
  display_name = "Emisar: Recurrent Job Failed"
  combiner     = "OR"

  documentation {
    content   = "A supervised recurrent job crashed at the executor boundary (the `recurrent_job.failed` log line names the `job`). These sweeps drive dispatch timeouts, event/run retention, and the fleet-observability signal, so a crash-looping one silently stops that housekeeping. Check the failing job's error and whether it is a one-off or looping, plus any recent deploy touching that context's jobs/."
    mime_type = "text/markdown"
  }

  user_labels = {
    component = "background-jobs"
    signal    = "errors"
  }

  conditions {
    display_name = "Any Recurrent Job Crash in 5 Minutes"
    condition_threshold {
      filter          = "resource.type = \"gce_instance\" AND metric.type = \"logging.googleapis.com/user/${google_logging_metric.application["recurrent_job_failures"].name}\""
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

  documentation {
    content   = "A Paddle lifecycle or billable-runner quantity reconciliation failed. Lifecycle failures can leave plan gating stale; quantity failures can leave the customer under- or overbilled. Check the log message and error, compare the affected subscription row and runner count with Paddle, and verify the API key still has subscription write authority before retrying the reconciliation."
    mime_type = "text/markdown"
  }

  user_labels = {
    component = "billing"
    signal    = "errors"
  }

  conditions {
    display_name = "Any Paddle Reconciliation Failure in 5 Minutes"
    condition_threshold {
      filter          = "resource.type = \"gce_instance\" AND metric.type = \"logging.googleapis.com/user/${google_logging_metric.application["billing_sync_failures"].name}\""
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

  documentation {
    content   = "BEAM peer discovery or node distribution is failing (`cluster discovery failed` / `cluster: can't connect`), so the portal nodes may not have formed a cluster — PubSub fan-out and every cluster-singleton job (dispatch timeout, fleet observability) then run on the wrong node count or not at all. Check the log's error, whether instances resolve each other through GCE discovery (EMISAR_CLUSTER_PROJECT + the cluster tag), and any recent firewall or MIG change. A single node still serves; this is a degraded-coordination signal, not an outage."
    mime_type = "text/markdown"
  }

  user_labels = {
    component = "clustering"
    signal    = "availability"
  }

  conditions {
    display_name = "Persistent Peer Discovery or Distribution Failures in 5 Minutes"
    condition_threshold {
      filter          = "resource.type = \"gce_instance\" AND metric.type = \"logging.googleapis.com/user/${google_logging_metric.application["cluster_failures"].name}\""
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
# watch both its values and its continued presence. Leadership may move the
# singleton emitter between VMs, so absence detection reduces all VM series to
# one fleet signal before evaluating the gap. Its three counter metrics are the
# fleet_* and dispatch_backlog keys in local.application_log_metrics above.

resource "google_monitoring_alert_policy" "fleet_observability_absent" {
  display_name = "Emisar: Fleet Observability Silent"
  combiner     = "OR"

  documentation {
    content   = "The cluster-singleton `fleet.observability` heartbeat has been absent for five minutes. The zero-runner and dispatch-backlog alerts are blind while this emitter is silent, so treat this as loss of fleet-health coverage. Check the FleetObservability recurrent job, cluster leadership and formation, Portal logs, and any recent deploy. The condition reduces every VM series into one fleet signal so a normal leadership move or VM replacement does not page on the old instance."
    mime_type = "text/markdown"
  }

  user_labels = {
    component = "runner-fleet"
    signal    = "telemetry"
  }

  conditions {
    display_name = "No Fleet Observability Heartbeat for 5 Minutes"
    condition_absent {
      filter   = "resource.type = \"gce_instance\" AND metric.type = \"logging.googleapis.com/user/${google_logging_metric.application["fleet_observability_ticks"].name}\""
      duration = "300s"
      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
      }
    }
  }

  notification_channels = local.paging_notification_channels
}

resource "google_monitoring_alert_policy" "fleet_no_connected_runners" {
  display_name = "Emisar: Runner Fleet Offline"
  combiner     = "OR"

  documentation {
    content   = "Every runner is disconnected fleet-wide while the site stays up, so all dispatches are stranded and no customer action can execute. /readyz and lb_5xx do not catch this (a WebSocket close is not a 5xx and the database is healthy). Check for a recent portal deploy or an LB backend-timeout change, the runner WebSocket ingress path, and whether runners are reconnecting; the emisar.runners.connection.* gauges carry the fleet-wide trend (deliberately not per-account), and the runner audit trail's connect/disconnect events carry the per-account detail."
    mime_type = "text/markdown"
  }

  user_labels = {
    component = "runner-fleet"
    signal    = "availability"
  }

  conditions {
    display_name = "Zero Connected Runners Fleet-Wide for 5 Minutes"
    condition_threshold {
      filter          = "resource.type = \"gce_instance\" AND metric.type = \"logging.googleapis.com/user/${google_logging_metric.application["fleet_no_connected_runners"].name}\""
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
    display_name = "Pending Dispatch Backlog Above Threshold for 10 Minutes"
    condition_threshold {
      filter          = "resource.type = \"gce_instance\" AND metric.type = \"logging.googleapis.com/user/${google_logging_metric.application["dispatch_backlog"].name}\""
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

moved {
  from = google_logging_metric.recurrent_job_failures
  to   = google_logging_metric.application["recurrent_job_failures"]
}

moved {
  from = google_logging_metric.billing_sync_failures
  to   = google_logging_metric.application["billing_sync_failures"]
}

moved {
  from = google_logging_metric.cluster_failures
  to   = google_logging_metric.application["cluster_failures"]
}

moved {
  from = google_logging_metric.fleet_observability_ticks
  to   = google_logging_metric.application["fleet_observability_ticks"]
}

moved {
  from = google_logging_metric.fleet_no_connected_runners
  to   = google_logging_metric.application["fleet_no_connected_runners"]
}

moved {
  from = google_logging_metric.dispatch_backlog
  to   = google_logging_metric.application["dispatch_backlog"]
}
