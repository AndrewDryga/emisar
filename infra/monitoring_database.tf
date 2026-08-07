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
