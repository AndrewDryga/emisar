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

  depends_on = [
    google_project_service.apis,
    google_project_iam_member.terraform_apply_authority,
  ]
}

resource "google_logging_project_sink" "security_evidence" {
  name = "emisar-security-evidence"
  destination = format(
    "logging.googleapis.com/projects/%s/locations/global/buckets/%s",
    var.project_id,
    google_logging_project_bucket_config.security_evidence.bucket_id,
  )
  # The provider normalizes log-bucket sinks to a unique identity on readback.
  # Match that state; a same-project log-bucket destination still needs no
  # cross-project IAM grant.
  unique_writer_identity = true

  filter = <<-FILTER
    (log_id("cloudaudit.googleapis.com/data_access") AND (
      protoPayload.serviceName="secretmanager.googleapis.com"
      OR protoPayload.serviceName="sqladmin.googleapis.com"
      OR (protoPayload.serviceName="cloudsql.googleapis.com" AND (
        protoPayload.methodName="cloudsql.instances.login"
        OR (
          protoPayload.methodName="cloudsql.instances.query"
          AND protoPayload.request."@type"="type.googleapis.com/google.cloud.sql.audit.v1.PgAuditEntry"
          AND (protoPayload.request.auditClass="DDL" OR protoPayload.request.auditClass="ROLE")
        )
      ))
    ))
    OR (log_id("cloudaudit.googleapis.com/activity") AND protoPayload.methodName:"SetIamPolicy")
  FILTER
}
