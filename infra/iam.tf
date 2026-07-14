# ── Least-privilege service account for the portal instances ────────────────
resource "google_service_account" "vm" {
  project      = var.project_id
  account_id   = "emisar-vm"
  display_name = "Emisar Control Plane Instances"
}

# The HCP apply identity already holds project IAM administration. Record the
# narrower service role required by Logging resources in this workspace.
resource "google_project_iam_member" "terraform_apply_authority" {
  project = var.project_id
  role    = "roles/logging.configWriter"
  member  = "serviceAccount:terraform@${var.project_id}.iam.gserviceaccount.com"
}

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

resource "google_project_iam_custom_role" "cluster_discovery" {
  project     = var.project_id
  role_id     = "emisarClusterDiscovery"
  title       = "Emisar Cluster Discovery"
  description = "List Compute Engine instances for regional MIG peer discovery."
  permissions = ["compute.instances.list"]
  stage       = "GA"
}

resource "google_project_iam_member" "vm_cluster_discovery" {
  project = var.project_id
  role    = google_project_iam_custom_role.cluster_discovery.name
  member  = "serviceAccount:${google_service_account.vm.email}"
}

resource "google_project_iam_member" "vm_cloudsql" {
  for_each = toset([
    "roles/cloudsql.client",
    "roles/cloudsql.instanceUser",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.vm.email}"

  condition {
    title       = "emisar_database_only"
    description = "The portal VM may connect and use IAM login only on the emisar instance."
    expression  = "resource.name == 'projects/${var.project_id}/instances/emisar' && resource.type == 'sqladmin.googleapis.com/Instance'"
  }
}

# ── Cloud Audit Logs ────────────────────────────────────────────────────────────────
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
