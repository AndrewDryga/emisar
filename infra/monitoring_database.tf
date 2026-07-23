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

