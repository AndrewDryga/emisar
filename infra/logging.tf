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

# Google's load-balancer proxies and health checkers (35.191.0.0/16,
# 130.211.0.0/22) probe every backend on a short interval; those probes reach the
# VMs directly, so they never appear in the LB request logs — they land in VPC
# flow logs, where at scale they dominate volume while carrying no forensic
# signal. The actor of interest is a VM's own egress to the internet (via Cloud
# NAT), and real client requests are already captured in the LB request logs.
# Keep those intra-fabric source ranges out of Logging storage; every other flow
# — anything that could reveal an unexpected talker — is retained.
resource "google_logging_project_exclusion" "lb_healthcheck_flows" {
  name        = "emisar-exclude-lb-healthcheck-flows"
  description = "Google LB health-check + proxy source ranges are noise in VPC flow logs; keep them out of Logging storage."

  filter = <<-FILTER
    resource.type="gce_subnetwork"
    log_id("compute.googleapis.com/vpc_flows")
    (
      ip_in_net(jsonPayload.connection.src_ip, "35.191.0.0/16")
      OR ip_in_net(jsonPayload.connection.src_ip, "130.211.0.0/22")
    )
  FILTER
}
