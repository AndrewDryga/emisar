# ── Least-privilege service account for the portal instances ─────────────────
# No Owner/Editor. Each role below is the minimum the instance needs; secret
# access is granted per-secret in secrets.tf, not project-wide.
resource "google_service_account" "vm" {
  account_id   = "emisar-vm"
  display_name = "Emisar Control Plane Instances"
}

# Ship logs + metrics (observability / SOC 2 monitoring evidence).
resource "google_project_iam_member" "vm_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.vm.email}"
}

resource "google_project_iam_member" "vm_monitoring" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.vm.email}"
}

# Read-only Compute access so the libcluster GCE strategy can list the MIG's
# instances (compute.instances.list) to discover its BEAM cluster peers.
resource "google_project_iam_member" "vm_compute_viewer" {
  project = var.project_id
  role    = "roles/compute.viewer"
  member  = "serviceAccount:${google_service_account.vm.email}"
}

# No image-registry role: the portal image is pulled anonymously from PUBLIC
# GHCR — self-hosters run the exact same artifact (see var.container_image).

# Connect to Cloud SQL (the connection is over the private VPC path; this grant
# is what an IAM-auth or Auth-Proxy hardening would build on).
resource "google_project_iam_member" "vm_cloudsql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.vm.email}"
}

# ── Cloud Audit Logs — Data Access logging (SOC 2: CC7 audit trail) ───────────
# Admin Activity logs are always-on + retained 400 days by default. Data Access
# logs (who READ what — Secret Manager access, SQL admin reads) are off by
# default; turn them on for the security-relevant services. DATA_WRITE/DATA_READ
# across these services is the record an auditor asks for.
resource "google_project_iam_audit_config" "data_access" {
  project = var.project_id
  service = "allServices"

  audit_log_config {
    log_type = "ADMIN_READ"
  }
  audit_log_config {
    log_type = "DATA_READ"
  }
  audit_log_config {
    log_type = "DATA_WRITE"
  }
}
