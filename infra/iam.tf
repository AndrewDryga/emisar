# ── Least-privilege service account for the portal instances ────────────────
resource "google_service_account" "vm" {
  depends_on = [google_project_service.apis]

  project      = var.project_id
  account_id   = "emisar-vm"
  display_name = "Emisar Control Plane Instances"
}

resource "google_service_account" "livebook" {
  depends_on = [google_project_service.apis]

  count = var.livebook_enabled ? 1 : 0

  project      = var.project_id
  account_id   = "emisar-livebook"
  display_name = "Emisar Livebook Admin Workbench"
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

# Reusing the colocated admin runner means its fixed GCP pack programs execute
# as the portal VM identity. Keep that new authority read-only even though the
# runner exposes every installed action risk tier: mutation attempts must still
# fail at Google's authorization boundary.
resource "google_project_iam_member" "vm_operations_read" {
  for_each = toset([
    "roles/certificatemanager.viewer",
    "roles/cloudsql.viewer",
    "roles/compute.viewer",
    "roles/dns.reader",
    "roles/iam.serviceAccountViewer",
    "roles/iam.workloadIdentityPoolViewer",
    "roles/monitoring.viewer",
    "roles/serviceusage.serviceUsageConsumer",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.vm.email}"
}

# Storage reads are scoped to the two buckets this project actually has, not
# granted project-wide. The unconditioned grant was bounded only by the current
# inventory happening to contain nothing private; the next bucket — a database
# export, a log sink, an audit-export staging area — would have been silently
# readable by the VM SA, and therefore by every action the colocated admin
# runner can run, with no plan diff to review.
resource "google_storage_bucket_iam_member" "vm_bucket_read" {
  for_each = {
    for pair in setproduct(
      [google_storage_bucket.pack_registry.name, google_storage_bucket.mta_sts.name],
      ["roles/storage.bucketViewer", "roles/storage.objectViewer"]
    ) : "${pair[0]}:${pair[1]}" => { bucket = pair[0], role = pair[1] }
  }

  bucket = each.value.bucket
  role   = each.value.role
  member = "serviceAccount:${google_service_account.vm.email}"
}

resource "google_project_iam_custom_role" "vm_storage_policy_reader" {
  depends_on = [google_project_service.apis]

  project     = var.project_id
  role_id     = "emisarStoragePolicyReader"
  title       = "Emisar Storage Policy Reader"
  description = "Read bucket IAM policies for governed storage inventory without storage mutation authority."
  permissions = ["storage.buckets.getIamPolicy"]
  stage       = "GA"

}

resource "google_project_iam_member" "vm_storage_policy_reader" {
  project = var.project_id
  role    = google_project_iam_custom_role.vm_storage_policy_reader.name
  member  = "serviceAccount:${google_service_account.vm.email}"
}

resource "google_project_iam_member" "livebook_logging" {
  count = var.livebook_enabled ? 1 : 0

  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.livebook[0].email}"
}

resource "google_project_iam_member" "livebook_monitoring" {
  count = var.livebook_enabled ? 1 : 0

  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.livebook[0].email}"
}

resource "google_project_iam_custom_role" "cluster_discovery" {
  depends_on = [google_project_service.apis]

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

resource "google_project_iam_member" "livebook_cluster_discovery" {
  count = var.livebook_enabled ? 1 : 0

  project = var.project_id
  role    = google_project_iam_custom_role.cluster_discovery.name
  member  = "serviceAccount:${google_service_account.livebook[0].email}"
}

resource "google_project_iam_custom_role" "livebook_backend_reader" {
  depends_on = [google_project_service.apis]

  count = var.livebook_enabled ? 1 : 0

  project     = var.project_id
  role_id     = "emisarLivebookBackendReader"
  title       = "Emisar Livebook Backend Reader"
  description = "Read the Livebook backend numeric ID used as the signed IAP JWT audience."
  permissions = ["compute.backendServices.get"]
  stage       = "GA"

}

resource "google_project_iam_member" "livebook_backend_reader" {
  count = var.livebook_enabled ? 1 : 0

  project = var.project_id
  role    = google_project_iam_custom_role.livebook_backend_reader[0].name
  member  = "serviceAccount:${google_service_account.livebook[0].email}"
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

resource "google_project_iam_member" "livebook_cloudsql" {
  for_each = var.livebook_enabled ? toset([
    "roles/cloudsql.client",
    "roles/cloudsql.instanceUser",
  ]) : toset([])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.livebook[0].email}"

  condition {
    title       = "emisar_livebook_database_only"
    description = "The Livebook VM may connect and use IAM login only on the emisar instance."
    expression  = "resource.name == 'projects/${var.project_id}/instances/emisar' && resource.type == 'sqladmin.googleapis.com/Instance'"
  }
}

# The apply identity already manages project IAM, but IAP resource policies use
# a separate permission family. Keep that authority to the two exact methods
# Terraform needs for the per-backend personal access binding.
resource "google_project_iam_custom_role" "terraform_iap_policy" {
  depends_on = [google_project_service.apis]

  count = var.livebook_enabled ? 1 : 0

  project     = var.project_id
  role_id     = "emisarTerraformIAPPolicy"
  title       = "Emisar Terraform IAP Policy"
  description = "Manage IAM policy on the Emisar IAP web backend."
  permissions = [
    "iap.webServices.getIamPolicy",
    "iap.webServices.setIamPolicy",
  ]
  stage = "GA"

}

resource "google_project_iam_member" "terraform_iap_policy" {
  count = var.livebook_enabled ? 1 : 0

  project = var.project_id
  role    = google_project_iam_custom_role.terraform_iap_policy[0].name
  member  = "serviceAccount:terraform@${var.project_id}.iam.gserviceaccount.com"
}

resource "terraform_data" "livebook_iap_policy_propagated" {
  count = var.livebook_enabled ? 1 : 0

  triggers_replace = [google_project_iam_member.terraform_iap_policy[0].id]

  # Project IAM writes can become visible before the permission is usable by
  # the apply identity. Avoid racing the immediately following IAP policy call.
  provisioner "local-exec" {
    command = "sleep 60"
  }
}

resource "google_iap_web_backend_service_iam_member" "livebook_user" {
  count = var.livebook_enabled && nonsensitive(var.livebook_iap_iam_user != null) ? 1 : 0

  project             = var.project_id
  web_backend_service = google_compute_backend_service.livebook[0].name
  role                = "roles/iap.httpsResourceAccessor"
  member              = "user:${var.livebook_iap_iam_user}"

  depends_on = [terraform_data.livebook_iap_policy_propagated]
}

# Keep human database access attributable to a personal IAM identity. These
# roles authorize connector login only for this instance; PostgreSQL privileges
# remain separately bounded by database.tf.
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
# emisar because that is the only instance where database.tf creates this IAM user.
resource "google_project_iam_member" "database_operator_studio" {
  count = nonsensitive(var.database_operator_iam_user != null) ? 1 : 0

  project = var.project_id
  role    = "roles/cloudsql.studioUser"
  member  = "user:${var.database_operator_iam_user}"

  # Scoped to the one instance, like every other Cloud SQL grant here. Granted
  # project-wide it was bounded only by there happening to be a single instance
  # — and `./run ops drill pitr --apply` creates a second one, so that is a
  # scheduled break, not a hypothetical.
  condition {
    title       = "emisar_database_only"
    description = "The database operator may open Studio only on the emisar instance."
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
