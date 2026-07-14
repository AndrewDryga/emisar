# A locked, filtered evidence store keeps security events for a normal annual
# audit period without retaining ordinary application request or workload logs.
resource "google_logging_project_bucket_config" "security_evidence" {
  project        = var.project_id
  location       = "global"
  bucket_id      = "emisar-security-evidence"
  retention_days = 400
  locked         = true

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.apis]
}

resource "google_logging_project_sink" "security_evidence" {
  name = "emisar-security-evidence"
  destination = format(
    "logging.googleapis.com/projects/%s/locations/global/buckets/%s",
    var.project_id,
    google_logging_project_bucket_config.security_evidence.bucket_id,
  )
  # A same-project Logging bucket uses the shared Logs Router writer, so this
  # sink does not require a dedicated service account or IAM grant.
  unique_writer_identity = false

  filter = <<-FILTER
    (log_id("cloudaudit.googleapis.com/data_access") AND (protoPayload.serviceName="secretmanager.googleapis.com" OR protoPayload.serviceName="sqladmin.googleapis.com"))
    OR (resource.type="cloudsql_database" AND log_id("cloudsql.googleapis.com/postgres.log") AND (textPayload:"AUDIT:" OR jsonPayload.message:"AUDIT:"))
    OR (log_id("cloudaudit.googleapis.com/activity") AND protoPayload.methodName:"SetIamPolicy")
  FILTER
}
