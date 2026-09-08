# Log-based and custom metrics cannot look back over 25h in a PromQL alert,
# including any retest window. Publish the backup's timestamp as a FRESH gauge
# instead: its value can be older than 30h without reading old metric points.
# https://cloud.google.com/monitoring/alerts/using-promql#restrictions
locals {
  backup_timestamp_metric = "custom.googleapis.com/emisar/cloudsql/last_automated_backup_timestamp"
  backup_timestamp_series = "custom_googleapis_com:emisar_cloudsql_last_automated_backup_timestamp{monitored_resource=\"global\",project_id=\"${var.project_id}\",instance_id=\"${google_sql_database_instance.emisar.name}\"}"
}

resource "google_monitoring_metric_descriptor" "backup_timestamp" {
  project      = var.project_id
  type         = local.backup_timestamp_metric
  metric_kind  = "GAUGE"
  value_type   = "DOUBLE"
  unit         = "s{epoch}"
  display_name = "Emisar: Latest Automated Backup"
  description  = "Unix completion timestamp of the latest successful automated Cloud SQL backup; zero means a complete inventory found none. Point time records the inventory check."

  labels {
    key         = "instance_id"
    value_type  = "STRING"
    description = "Cloud SQL instance ID."
  }

  depends_on = [google_project_service.apis]
}

resource "google_service_account" "backup_checker" {
  project      = var.project_id
  account_id   = "emisar-backup-checker"
  display_name = "Emisar Backup Checker"
  depends_on   = [google_project_service.apis]
}

resource "google_service_account" "backup_scheduler" {
  project      = var.project_id
  account_id   = "emisar-backup-scheduler"
  display_name = "Emisar Backup Check Scheduler"
  depends_on   = [google_project_service.apis]
}

resource "google_project_iam_custom_role" "backup_checker" {
  project     = var.project_id
  role_id     = "emisarBackupChecker"
  title       = "Emisar Backup Checker"
  description = "List backup inventory and write the backup health metric, without database access or backup mutations."
  permissions = ["cloudsql.backupRuns.list", "monitoring.timeSeries.create"]
  stage       = "GA"
}

resource "google_project_iam_member" "backup_checker" {
  project = var.project_id
  role    = google_project_iam_custom_role.backup_checker.name
  member  = "serviceAccount:${google_service_account.backup_checker.email}"
}

# Workflows grants are project-level. Grant only execution creation (not the
# predefined invoker's cancellation/callback/read authority), and keep the
# scheduler target fixed. Revisit this grant if the project adds other workflows.
resource "google_project_iam_custom_role" "backup_scheduler" {
  project     = var.project_id
  role_id     = "emisarBackupScheduler"
  title       = "Emisar Backup Check Scheduler"
  description = "Start the scheduled backup inventory workflow."
  permissions = ["workflows.executions.create"]
  stage       = "GA"
}

resource "google_project_iam_member" "backup_scheduler" {
  project = var.project_id
  role    = google_project_iam_custom_role.backup_scheduler.name
  member  = "serviceAccount:${google_service_account.backup_scheduler.email}"
}

resource "google_workflows_workflow" "backup_check" {
  project             = var.project_id
  region              = var.region
  name                = "emisar-backup-check"
  description         = "Report the latest successful automated Cloud SQL backup independently of Portal."
  service_account     = google_service_account.backup_checker.id
  call_log_level      = "LOG_ERRORS_ONLY"
  deletion_protection = false
  source_contents = templatefile("${path.module}/runtime/backup-check/workflow.yaml", {
    project_id  = var.project_id
    instance_id = google_sql_database_instance.emisar.name
    metric_type = google_monitoring_metric_descriptor.backup_timestamp.type
  })

  depends_on = [
    google_project_iam_member.terraform_backup_check,
    google_project_iam_member.backup_checker,
    google_service_account_iam_member.terraform_backup_check_act_as,
  ]
}

resource "google_cloud_scheduler_job" "backup_check" {
  project          = var.project_id
  region           = var.region
  name             = "emisar-backup-check"
  description      = "Check the latest successful automated database backup every ten minutes."
  schedule         = "*/10 * * * *"
  time_zone        = "Etc/UTC"
  attempt_deadline = "30s"
  paused           = false

  http_target {
    uri         = "https://workflowexecutions.googleapis.com/v1/${google_workflows_workflow.backup_check.id}/executions"
    http_method = "POST"
    body        = base64encode("{}")
    headers     = { "Content-Type" = "application/json" }

    oauth_token {
      service_account_email = google_service_account.backup_scheduler.email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }

  depends_on = [
    google_project_iam_member.backup_scheduler,
    google_project_iam_member.terraform_backup_check,
    google_service_account_iam_member.terraform_backup_check_act_as,
  ]
}

# Preserve 30h: a daily schedule can legitimately leave over 26h between
# successful completions. Ten-minute inventory checks need only a short metric
# window, not a shorter backup-age threshold. The separate alarm below covers a
# checker that never starts or stops writing, including IAM/API failures.
resource "google_monitoring_alert_policy" "db_backup_absent" {
  display_name = "Emisar: Cloud SQL Backup Not Running"
  combiner     = "OR"

  documentation {
    content   = "The latest successful Cloud SQL automated backup is at least 30 hours old, or the complete backup inventory contains none. Check the backup schedule, Cloud SQL operations and quota, and the PITR window. Take an on-demand backup if needed for recovery; it does not clear this alert because the automated schedule still needs repair. The checker reads existing backups, so a new installation does not need to wait for the next nightly run."
    mime_type = "text/markdown"
  }

  user_labels = { component = "cloud-sql", signal = "durability" }

  conditions {
    display_name = "No Successful Automated Backup In 30 Hours"
    condition_prometheus_query_language {
      query                     = "time() - last_over_time(${local.backup_timestamp_series}[30m]) >= 108000"
      duration                  = "0s"
      evaluation_interval       = "300s"
      disable_metric_validation = true
    }
  }

  notification_channels = local.paging_notification_channels
  depends_on            = [google_monitoring_metric_descriptor.backup_timestamp]
}

resource "google_monitoring_alert_policy" "db_backup_checker_stale" {
  display_name = "Emisar: Cloud SQL Backup Checker Not Reporting"
  combiner     = "OR"

  documentation {
    content   = "The Cloud SQL backup checker has not reported a complete inventory in 30 minutes. Backup freshness is unknown. Check the emisar-backup-check Scheduler job and Workflow execution errors, then their service-account permissions and the Cloud SQL and Monitoring APIs. A successful Scheduler request only starts the Workflow; confirm the Workflow writes its metric. A new installation can alert until its first scheduled check succeeds."
    mime_type = "text/markdown"
  }

  user_labels = { component = "cloud-sql", signal = "durability" }

  conditions {
    display_name = "No Backup Inventory Check In 30 Minutes"
    condition_prometheus_query_language {
      query                     = "absent_over_time(${local.backup_timestamp_series}[30m])"
      duration                  = "0s"
      evaluation_interval       = "300s"
      disable_metric_validation = true
    }
  }

  notification_channels = local.paging_notification_channels
  depends_on            = [google_monitoring_metric_descriptor.backup_timestamp]
}
