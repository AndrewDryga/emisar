locals {
  cloud_init = templatefile("${path.module}/templates/cloud-init.yaml", {
    container_image   = var.container_image
    project_id        = var.project_id
    domain            = var.domain
    app_port          = var.app_port
    mailer_from_email = var.mailer_from_email
    cluster_value     = "emisar"
    disable_billing   = var.disable_billing
    app_secrets       = local.app_secrets
  })
}

# ── Health check (drives both the LB backend and MIG auto-healing) ────────────
# /healthz is excluded from the compile-time force_ssl redirect (config/prod.exs),
# so a plain-HTTP probe returns 200 instead of a 301.
resource "google_compute_health_check" "app" {
  name                = "emisar-healthz"
  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3

  http_health_check {
    request_path = "/healthz"
    port         = var.app_port
  }

  depends_on = [google_project_service.apis]
}

# ── Capacity reservation: the base count is always schedulable ────────────────
# Rollouts and auto-healing fail when the zone happens to be out of capacity at
# the moment a replacement instance is created — the classic stuck deploy.
# Reserve exactly var.instance_count (the running base; surge is deliberately
# NOT reserved): the update policy below replaces WITHOUT surge, so every
# recreate frees its reserved slot and re-fills it — capacity-guaranteed
# rollouts, and the reservation is always consumed by the fleet (an idle
# reservation bills like a running instance, so consumed == free).
resource "google_compute_reservation" "emisar" {
  name = "emisar"
  zone = var.zone

  # Only instances that explicitly target this reservation consume it — a
  # stray VM in the project can't silently eat the fleet's slots.
  specific_reservation_required = true

  specific_reservation {
    count = var.instance_count
    instance_properties {
      machine_type = var.machine_type
    }
  }
}

# ── Instance template: Container-Optimized OS running the portal container ────
data "google_compute_image" "cos" {
  project = "cos-cloud"
  family  = "cos-stable"
}

resource "google_compute_instance_template" "emisar" {
  name_prefix  = "emisar-"
  machine_type = var.machine_type
  tags         = ["emisar"]

  # libcluster's GCE strategy (Emisar.Cluster.GCE) finds cluster peers by this label.
  labels = {
    cluster_name = "emisar"
  }

  disk {
    source_image = data.google_compute_image.cos.self_link
    auto_delete  = true
    boot         = true
    disk_size_gb = 30
    disk_type    = "pd-balanced"
  }

  # No external IP — egress (image pull, Secret Manager, Cloud SQL, logging) goes
  # through Cloud NAT / Private Google Access; ingress arrives from the LB. IAP
  # SSH tunnels through Google, so it needs no public IP.
  network_interface {
    network    = google_compute_network.emisar.id
    subnetwork = google_compute_subnetwork.emisar.id
  }

  # Shielded VM: secure boot + vTPM + integrity monitoring (SOC 2 host hardening).
  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  # Every fleet instance consumes the base-count reservation above — this is
  # what makes replacement creates immune to zonal capacity stockouts.
  reservation_affinity {
    type = "SPECIFIC_RESERVATION"
    specific_reservation {
      key    = "compute.googleapis.com/reservation-name"
      values = [google_compute_reservation.emisar.name]
    }
  }

  metadata = {
    user-data                 = local.cloud_init
    google-logging-enabled    = "true"
    google-monitoring-enabled = "true"
    # Block project-wide SSH keys; access is IAP + OS Login only.
    block-project-ssh-keys = "true"
    enable-oslogin         = "TRUE"
  }

  service_account {
    email  = google_service_account.vm.email
    scopes = ["cloud-platform"]
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [google_project_service.apis]
}

# ── Regional Managed Instance Group: auto-healing + rolling updates ──────────
# emisar clusters via the GCE libcluster strategy (see Emisar.Cluster.GCE +
# rel/env.sh.eex), so target_size > 1 forms one BEAM cluster — Phoenix PubSub +
# Presence span nodes and runs don't strand in :sent. DB migrations run on boot
# guarded by Ecto's advisory lock (cloud-init), so concurrent instances are safe.
resource "google_compute_region_instance_group_manager" "emisar" {
  name                             = "emisar"
  base_instance_name               = "emisar"
  region                           = var.region
  target_size                      = var.instance_count
  distribution_policy_target_shape = "BALANCED"
  # Pinned to the reservation's zone so every instance can consume it. Zone
  # redundancy at 2+ instances = more zones with a per-zone reservation each —
  # a deliberate change (see var.zone).
  distribution_policy_zones = [var.zone]

  # Block `terraform apply` until the rollout is healthy, so a broken deploy FAILS
  # the apply instead of returning while the fleet is down.
  wait_for_instances        = true
  wait_for_instances_status = "UPDATED"

  version {
    instance_template = google_compute_instance_template.emisar.id
  }

  named_port {
    name = "http"
    port = var.app_port
  }

  auto_healing_policies {
    health_check = google_compute_health_check.app.id
    # Generous: the container pulls, runs migrations, then boots.
    initial_delay_sec = 240
  }

  # NO surge, on purpose: a surge instance needs capacity OUTSIDE the
  # reservation and fails the whole rollout on a zonal stockout — the exact
  # deploys-often-fail mode reservations exist to kill. Delete-then-recreate
  # frees a reserved slot and re-fills it, so a rollout can always complete;
  # the cost is a brief per-instance unavailability window during deploys.
  update_policy {
    type                  = "PROACTIVE"
    minimal_action        = "REPLACE"
    max_surge_fixed       = 0
    max_unavailable_fixed = 1
    # Required explicitly: the BALANCED target shape does not support
    # proactive cross-zone redistribution, and the API rejects the default
    # (UNSPECIFIED) instead of inferring NONE.
    instance_redistribution_type = "NONE"
  }

  timeouts {
    create = "25m"
    update = "25m"
    delete = "15m"
  }

  # Catch the Paddle misconfiguration at PLAN time instead of a ~25-minute failed
  # rollout: runtime.exs raises at boot when billing is enabled but any paddle_*
  # credential is missing, so the MIG would never go healthy. Whether the vars are
  # set is not itself secret — unwrap just the boolean.
  lifecycle {
    precondition {
      condition = var.disable_billing || nonsensitive(
        var.paddle_api_key != "" && var.paddle_webhook_secret != "" && var.paddle_client_token != ""
      )
      error_message = "Billing is enabled (disable_billing = false) but paddle_api_key / paddle_webhook_secret / paddle_client_token are not all set in the TFC workspace. Set all three, or set disable_billing = true to ship the Paddle stub."
    }
  }

  # Runtime boot prerequisites: without explicit edges the MIG can come up before
  # NAT / firewall / IAM / the database converge, so instances fail to pull the
  # image, read secrets, migrate, or pass /healthz.
  depends_on = [
    google_project_service.apis,
    google_compute_router_nat.emisar,
    google_compute_firewall.lb_to_app,
    google_compute_firewall.cluster_dist,
    google_secret_manager_secret_iam_member.vm_access,
    google_secret_manager_secret_version.secret_key_base,
    google_project_iam_member.vm_compute_viewer,
    google_sql_database.emisar,
    google_secret_manager_secret_version.database_url,
  ]
}
