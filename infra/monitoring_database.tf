resource "google_monitoring_alert_policy" "db_cpu" {
  display_name = "Emisar: Cloud SQL CPU High"
  combiner     = "OR"

  documentation {
    content   = "Cloud SQL CPU has remained above 90% for five minutes. Use Query Insights and database activity to identify expensive queries, lock contention, connection pressure, or a workload change, and correlate the rise with the most recent Portal rollout before resizing the instance."
    mime_type = "text/markdown"
  }

  user_labels = {
    component = "cloud-sql"
    signal    = "cpu"
  }

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

  documentation {
    content   = "Cloud SQL disk utilization has remained above 90% for five minutes, leaving little headroom for writes, WAL, maintenance, and temporary work. Check current size, growth rate, automatic-storage settings and quota, then identify unexpected table, index, WAL, or temporary-file growth before capacity is exhausted."
    mime_type = "text/markdown"
  }

  user_labels = {
    component = "cloud-sql"
    signal    = "disk"
  }

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

  documentation {
    content   = "Cloud SQL memory utilization has remained above 90% for five minutes. Correlate the signal with active connections, query workload, cache behavior, swap, latency, and recent application changes; high memory alone is not proof of a leak, so identify the pressure source before restarting or resizing."
    mime_type = "text/markdown"
  }

  user_labels = {
    component = "cloud-sql"
    signal    = "memory"
  }

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
      filter          = "resource.type = \"cloudsql_database\" AND resource.labels.project_id = \"${var.project_id}\" AND resource.labels.database_id = \"${var.project_id}:${google_sql_database_instance.emisar.name}\" AND metric.type = \"cloudsql.googleapis.com/database/up\""
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

# Transaction-ID wraparound is the one Postgres failure mode that gives no
# user-visible symptom until the database force-stops writes — autovacuum
# normally keeps it near zero, so a climb past 70% means vacuum is stuck
# (long-lived transaction, abandoned replication slot) and needs a human
# well before the 100% hard stop.
resource "google_monitoring_alert_policy" "db_txid" {
  display_name = "Emisar: Cloud SQL Transaction ID Wraparound Risk"
  combiner     = "OR"

  documentation {
    content   = "PostgreSQL transaction-ID utilization has remained above 70% for 15 minutes, so normal autovacuum is not containing wraparound risk. Find the oldest open transactions, blocked or failing autovacuum work, and abandoned replication slots; remove the blocker and confirm utilization is falling before the database approaches its write-protection limit."
    mime_type = "text/markdown"
  }

  user_labels = {
    component = "cloud-sql"
    signal    = "txid"
  }

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


# Backups and PITR are the WHOLE recovery posture here: availability_type is
# ZONAL, so there is no failover and restore IS the recovery. Nothing alerted on
# a backup failing, so quota exhaustion, a maintenance regression, or a flag
# change would stop backups silently and the first anyone knew of it would be a
# restore attempted under incident pressure, against whatever the last good
# backup happened to be.
resource "google_logging_metric" "cloudsql_backup_failed" {
  project = var.project_id
  name    = "emisar_cloudsql_backup_failed"

  filter = join(" AND ", [
    "resource.type=\"cloudsql_database\"",
    "resource.labels.database_id=\"${var.project_id}:${google_sql_database_instance.emisar.name}\"",
    # cloudsql.instances.automatedBackup, NOT cloudsql.instances.backup. The
    # latter is the on-demand verb and never appears for the nightly run, so this
    # metric matched nothing: verified against the live project, where 30 days
    # held 27 automatedBackup entries and ZERO of the name this used to filter,
    # while `gcloud sql backups list` showed 24 unbroken AUTOMATED/SUCCESSFUL
    # runs. The alert could not fire, on the only recovery a ZONAL instance has.
    "protoPayload.methodName=\"cloudsql.instances.automatedBackup\"",
    "severity>=ERROR",
  ])

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
  }

  depends_on = [google_project_service.apis]
}

resource "google_monitoring_alert_policy" "db_backup_failed" {
  display_name = "Emisar: Cloud SQL Backup Failed"
  combiner     = "OR"

  documentation {
    content   = "A Cloud SQL backup operation failed. Restore is the recovery plan for this ZONAL instance, so treat a lapse as an availability incident: check Cloud SQL operations, quota, and the backup configuration, then confirm the most recent successful backup and PITR window."
    mime_type = "text/markdown"
  }

  user_labels = {
    component = "cloud-sql"
    signal    = "durability"
  }

  conditions {
    display_name = "Backup Operation Error In The Last Hour"
    condition_threshold {
      filter          = "resource.type = \"cloudsql_database\" AND metric.type = \"logging.googleapis.com/user/${google_logging_metric.cloudsql_backup_failed.name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"
      aggregations {
        alignment_period   = "3600s"
        per_series_aligner = "ALIGN_DELTA"
      }
    }
  }

  notification_channels = local.paging_notification_channels
}

# A backup that ERRORS is only half the failure mode. A backup that stops being
# ATTEMPTED — a disabled schedule, a maintenance or quota regression — errors
# nowhere and so alerts nobody, and on a ZONAL instance that silently retires
# the entire recovery plan. Only counting SUCCESSES and alerting on their
# absence covers it. The automated-backup system_event is exactly one INFO entry
# with status OK per completed run, so this metric is the failed-backup filter
# with the severity clause inverted; a run that errors is deliberately NOT
# counted, so a failing nightly keeps the absence alert armed rather than
# resetting its clock.
resource "google_logging_metric" "cloudsql_backup_succeeded" {
  project = var.project_id
  # Keep this name free of "/": the alert below interpolates it into a PromQL
  # metric name, where a slash would have to be spelled as an underscore.
  name = "emisar_cloudsql_backup_succeeded"

  filter = join(" AND ", [
    "resource.type=\"cloudsql_database\"",
    "resource.labels.database_id=\"${var.project_id}:${google_sql_database_instance.emisar.name}\"",
    "protoPayload.methodName=\"cloudsql.instances.automatedBackup\"",
    "severity=INFO",
  ])

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
  }

  depends_on = [google_project_service.apis]
}

# 30 hours, and it has to be PromQL to get there. Cloud SQL drifts the nightly
# run across a ~2.5h band (03:17-05:53 UTC over 45 days), so the largest HEALTHY
# gap measured on this instance is 26h06m and the band's worst case is 26h36m —
# while a metric-absence condition caps at one day and a DELTA log-based metric
# writes no zeros for an empty window, so every formulation inside that cap
# flaps. absent_over_time clears the measured gap by ~4h, is inside the
# two-year PromQL condition limit, and buys no standing capacity.
# Newly created, the policy fires until the next nightly run records its first
# success; the documentation says so, because the incident arrives before the
# metric has any data.
resource "google_monitoring_alert_policy" "db_backup_absent" {
  display_name = "Emisar: Cloud SQL Backup Not Running"
  combiner     = "OR"

  documentation {
    content   = "No successful Cloud SQL automated backup has been recorded for 30 hours, which is longer than the nightly schedule ever legitimately drifts. Restore is the recovery plan for this ZONAL instance, so treat the lapse as an availability incident: confirm backup configuration and retention are still enabled, look for a run that never started in Cloud SQL operations and quota, take a backup on demand, and verify the PITR window still covers the recovery objective. A newly created policy fires until the next nightly run records its first success."
    mime_type = "text/markdown"
  }

  user_labels = {
    component = "cloud-sql"
    signal    = "durability"
  }

  conditions {
    display_name = "No Successful Automated Backup In 30 Hours"
    condition_prometheus_query_language {
      query = "absent_over_time(logging_googleapis_com:user_${google_logging_metric.cloudsql_backup_succeeded.name}[30h])"
      # The 30h lookback is the whole damping; one true evaluation is the alert.
      # Re-running a 30h range query every 30s (the default) would be 10x the
      # work for a signal that moves once a day.
      duration            = "0s"
      evaluation_interval = "300s"
      # The metric descriptor above is created in this same apply and reaches
      # Monitoring asynchronously, so existence validation can reject the policy
      # on a cold apply. The name is interpolated from the resource, so it
      # cannot drift away from a real metric.
      disable_metric_validation = true
    }
  }

  notification_channels = local.paging_notification_channels
}
