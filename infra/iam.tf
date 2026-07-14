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

# Keep human database access attributable to a personal IAM identity. These
# roles authorize connector login only for this instance; PostgreSQL privileges
# remain separately bounded by db.tf.
resource "google_project_iam_member" "database_operator_cloudsql" {
  for_each = nonsensitive(var.database_operator_iam_user != null) ? toset([
    "roles/cloudsql.client",
    "roles/cloudsql.instanceUser",
  ]) : toset([])

  project = var.project_id
  role    = each.value
  member  = "user:${var.database_operator_iam_user}"

  condition {
    title       = "emisar_database_operator_only"
    description = "This binding permits database operator login only on the emisar instance."
    expression  = "resource.name == 'projects/${var.project_id}/instances/emisar' && resource.type == 'sqladmin.googleapis.com/Instance'"
  }
}

# Cloud SQL Studio needs project-scoped console discovery permissions that an
# instance condition would deny. Database authentication remains confined to
# emisar because that is the only instance where db.tf creates this IAM user.
resource "google_project_iam_member" "database_operator_studio" {
  count = nonsensitive(var.database_operator_iam_user != null) ? 1 : 0

  project = var.project_id
  role    = "roles/cloudsql.studioUser"
  member  = "user:${var.database_operator_iam_user}"
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
