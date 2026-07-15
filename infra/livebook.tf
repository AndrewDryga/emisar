locals {
  livebook_image        = "ghcr.io/livebook-dev/livebook:0.19.8@sha256:38eed8467d3df794dd36cbe722768e46d709b02e00368e0a06aa7508220a8763"
  livebook_port         = 8080
  livebook_backend_name = "emisar-livebook-backend"
  livebook_database_user = var.livebook_enabled ? trimsuffix(
    google_service_account.livebook[0].email,
    ".gserviceaccount.com",
  ) : ""
  livebook_notebooks = {
    for notebook in fileset("${path.module}/livebook/notebooks", "*.livemd") :
    notebook => file("${path.module}/livebook/notebooks/${notebook}")
  }

  livebook_ensure_images_script = templatefile("${path.module}/templates/livebook-ensure-images.sh", {
    livebook_image        = local.livebook_image
    cloud_sql_proxy_image = local.cloud_sql_proxy_image
  })
  livebook_prepare_data_script      = file("${path.module}/templates/livebook-prepare-data.sh")
  livebook_product_analytics_script = file("${path.module}/livebook/product_analytics.exs")
  livebook_cluster_nodes_script = templatefile("${path.module}/templates/livebook-cluster-nodes.sh", {
    project_id = var.project_id
  })
  livebook_start_script = templatefile("${path.module}/templates/start-livebook.sh", {
    project_id                    = var.project_id
    project_number                = data.google_project.current.number
    domain                        = var.domain
    livebook_image                = local.livebook_image
    livebook_port                 = local.livebook_port
    livebook_backend_name         = local.livebook_backend_name
    livebook_secret_version       = try(google_secret_manager_secret_version.livebook_secret_key_base[0].version, "")
    release_cookie_version        = try(google_secret_manager_secret_version.release_cookie[0].version, "")
    database_user                 = local.livebook_database_user
    database_user_uri             = urlencode(local.livebook_database_user)
    database_name                 = google_sql_database.emisar.name
    database_role                 = "emisar_owner"
    database_statement_timeout_ms = 30000
  })
  livebook_cloud_init = templatefile("${path.module}/templates/livebook-cloud-init.yaml", {
    cloud_sql_proxy_image             = local.cloud_sql_proxy_image
    livebook_port                     = local.livebook_port
    database_connection_name          = google_sql_database_instance.emisar.connection_name
    livebook_ensure_images_script     = local.livebook_ensure_images_script
    livebook_prepare_data_script      = local.livebook_prepare_data_script
    livebook_product_analytics_script = local.livebook_product_analytics_script
    livebook_cluster_nodes_script     = local.livebook_cluster_nodes_script
    livebook_start_script             = local.livebook_start_script
    livebook_notebooks                = local.livebook_notebooks
  })
}

# Notebook/configuration data survives instance replacement. Removing the
# workbench therefore requires an explicit reviewed disk-retirement change.
resource "google_compute_disk" "livebook_data" {
  count = var.livebook_enabled ? 1 : 0

  name = "emisar-livebook-data"
  zone = var.zones[0]
  type = "pd-standard"
  size = var.livebook_data_disk_size_gb

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.apis]
}

resource "google_compute_instance" "livebook" {
  count = var.livebook_enabled ? 1 : 0

  name                      = "emisar-livebook"
  zone                      = var.zones[0]
  machine_type              = var.livebook_machine_type
  tags                      = ["emisar-livebook"]
  allow_stopping_for_update = true

  # Deliberately omit cluster_name: portal libcluster must never auto-discover
  # this full-trust debugging node.
  labels = {
    role = "livebook"
  }

  boot_disk {
    auto_delete = true
    initialize_params {
      image = data.google_compute_image.cos.self_link
      size  = 20
      type  = "pd-balanced"
    }
  }

  attached_disk {
    source      = google_compute_disk.livebook_data[0].id
    device_name = "livebook-data"
    mode        = "READ_WRITE"
  }

  # No access_config means no public VM address. Browser traffic arrives only
  # through the IAP-enabled load-balancer backend.
  network_interface {
    network    = google_compute_network.emisar.id
    subnetwork = google_compute_subnetwork.emisar.id
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  metadata = {
    user-data                 = sensitive(local.livebook_cloud_init)
    google-logging-enabled    = "true"
    google-monitoring-enabled = "true"
    block-project-ssh-keys    = "true"
    enable-oslogin            = "TRUE"
  }

  service_account {
    email  = google_service_account.livebook[0].email
    scopes = ["cloud-platform"]
  }

  lifecycle {
    precondition {
      condition     = var.database_owner_role_ready
      error_message = "livebook_enabled requires database_owner_role_ready=true before assigning the IAM database principal."
    }

    precondition {
      condition     = nonsensitive(var.livebook_iap_iam_user != null)
      error_message = "livebook_enabled requires livebook_iap_iam_user so IAP never starts without an attributable user grant."
    }
  }

  depends_on = [
    google_compute_router_nat.emisar,
    google_compute_firewall.lb_to_livebook,
    google_compute_firewall.cluster_dist,
    google_project_iam_member.livebook_backend_reader,
    google_project_iam_member.livebook_cluster_discovery,
    google_secret_manager_secret_version.livebook_secret_key_base,
    google_secret_manager_secret_iam_member.livebook_release_cookie_access,
    google_sql_user.livebook,
  ]
}

resource "google_compute_instance_group" "livebook" {
  count = var.livebook_enabled ? 1 : 0

  name      = "emisar-livebook"
  zone      = var.zones[0]
  instances = [google_compute_instance.livebook[0].self_link]

  named_port {
    name = "livebook"
    port = local.livebook_port
  }
}
