locals {
  cloud_sql_proxy_image = "gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.23.0@sha256:54e23cad9aeeedbf88ab75f993146631b878035f702b31c51885a932e0c7286c"
  # The release image, instance firewall, MIG named port, and load-balancer
  # probes share this contract. Changing it requires a staged successor fleet;
  # it is not a routine workspace input.
  portal_port = 4000
  readiness_contract = {
    request_path        = "/readyz"
    port                = local.portal_port
    check_interval_sec  = 10
    timeout_sec         = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
  readiness_generation = substr(sha256(jsonencode(local.readiness_contract)), 0, 8)
  # A five-connection pool per VM leaves ample room on the production shared-core
  # tier for Cloud SQL internals and for old + new fleets to overlap during a
  # create-before-destroy MIG replacement or multi-zone surge.
  portal_database_pool_size = 5
  ensure_image_script = templatefile("${path.module}/templates/ensure-image.sh", {
    container_image       = var.container_image
    cloud_sql_proxy_image = local.cloud_sql_proxy_image
  })
  start_script = templatefile("${path.module}/templates/start.sh", {
    container_image          = var.container_image
    project_id               = var.project_id
    domain                   = var.domain
    app_port                 = local.portal_port
    mailer_from_email        = var.mailer_from_email
    cluster_value            = "emisar"
    disable_billing          = var.disable_billing
    runtime_secrets          = local.runtime_secrets
    database_connection_name = google_sql_database_instance.emisar.connection_name
    database_user            = trimsuffix(google_service_account.vm.email, ".gserviceaccount.com")
    database_name            = google_sql_database.emisar.name
    database_role            = "emisar_owner"
    database_pool_size       = local.portal_database_pool_size
    release_cookie_ready     = var.release_cookie_ready
  })
  cloud_init = templatefile("${path.module}/templates/cloud-init.yaml", {
    container_image          = var.container_image
    cloud_sql_proxy_image    = local.cloud_sql_proxy_image
    app_port                 = local.portal_port
    database_connection_name = google_sql_database_instance.emisar.connection_name
    ensure_image_script      = local.ensure_image_script
    start_script             = local.start_script
  })

  zone_reservation_counts = {
    for index, zone in var.zones : zone => (
      floor(var.instance_count / length(var.zones)) +
      (index < var.instance_count % length(var.zones) ? 1 : 0)
    )
  }
}

# ── Health checks: repair liveness is not traffic readiness ──────────────────
# Both paths bypass force_ssl because GCP probes the backend over plain HTTP.
# Auto-healing checks only the BEAM: a database outage must not restart every
# healthy VM. The load balancer additionally checks PostgreSQL before routing.
resource "google_compute_health_check" "liveness" {
  name                = "emisar-healthz"
  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3

  http_health_check {
    request_path = "/healthz"
    port         = local.portal_port
  }

  depends_on = [google_project_service.apis]
}

resource "google_compute_health_check" "readiness" {
  name                = "emisar-readyz-${local.readiness_generation}"
  check_interval_sec  = local.readiness_contract.check_interval_sec
  timeout_sec         = local.readiness_contract.timeout_sec
  healthy_threshold   = local.readiness_contract.healthy_threshold
  unhealthy_threshold = local.readiness_contract.unhealthy_threshold

  http_health_check {
    request_path = local.readiness_contract.request_path
    port         = local.readiness_contract.port
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [google_project_service.apis]
}

# ── Capacity reservation: steady-state fleet ─────────────────────────────────
# Guarantee capacity for the serving fleet without paying continuously for a
# rollout surge. Regional MIGs require fixed surge to be at least their zone
# count; those transient VMs use ordinary on-demand capacity, so a zonal
# stockout can delay a rollout without reducing existing serving capacity.
resource "google_compute_reservation" "emisar" {
  for_each = local.zone_reservation_counts

  # Zone + machine shape make every ForceNew successor name unique, so
  # create_before_destroy can actually create it before releasing the old slot.
  name = "emisar-${each.key}-${replace(var.machine_type, "_", "-")}"
  zone = each.key

  specific_reservation_required = false

  # The provider calls the reserved machine shape "specific_reservation" even
  # when consumption is automatic. Matching VMs may consume these slots.
  specific_reservation {
    count = each.value
    instance_properties {
      machine_type = var.machine_type
    }
  }

  # Changing a specifically targeted reservation to automatic consumption
  # requires replacement. Create the new base reservation before rolling the
  # template, then release the old reservation after its VMs are gone.
  lifecycle {
    create_before_destroy = true
  }

  depends_on = [google_project_service.apis]
}

# ── Instance template: Container-Optimized OS running the portal container ────
data "google_compute_image" "cos" {
  project = "cos-cloud"
  name    = var.cos_image
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

  # Base instances automatically consume the matching reservation above. Once
  # those slots are full, a rollout surge can still use on-demand capacity.
  reservation_affinity {
    type = "ANY_RESERVATION"
  }

  metadata = {
    user-data                 = sensitive(local.cloud_init)
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

  depends_on = [
    google_project_service.apis,
    google_compute_reservation.emisar,
  ]
}

# ── Regional Managed Instance Group: auto-healing + rolling updates ──────────
# emisar clusters via the GCE libcluster strategy (see Emisar.Cluster.GCE +
# rel/env.sh.eex), so target_size > 1 forms one BEAM cluster — Phoenix PubSub +
# Presence span nodes and runs don't strand in :sent. DB migrations run on boot
# guarded by Ecto's advisory lock in the release entrypoint, so concurrent instances are safe.
resource "google_compute_region_instance_group_manager" "emisar" {
  # Keep the operator-facing fleet name stable. A zone-set replacement cannot
  # create two same-named MIGs, so topology changes require an explicitly staged
  # migration rather than an ordinary one-plan replacement.
  name               = "emisar"
  base_instance_name = "emisar"
  region             = var.region
  # A blank database is bootstrapped before any application VM may start. The
  # reviewed readiness attestation raises this from zero after the IAM verifier
  # succeeds; restores already contain the owner role and skip that ceremony.
  target_size                      = var.database_owner_role_ready ? var.instance_count : 0
  distribution_policy_target_shape = "EVEN"
  distribution_policy_zones        = var.zones

  # Block `terraform apply` until the rollout is healthy, so a broken deploy FAILS
  # the apply instead of returning while the fleet is down.
  wait_for_instances        = true
  wait_for_instances_status = "UPDATED"

  version {
    instance_template = google_compute_instance_template.emisar.id
  }

  named_port {
    name = "http"
    port = local.portal_port
  }

  auto_healing_policies {
    health_check = google_compute_health_check.liveness.id
    # Generous: the container pulls and successfully migrates before the BEAM
    # starts answering /healthz.
    initial_delay_sec = 240
  }

  # Create a healthy replacement in every zone before removing an old VM.
  # Combined with LB readiness and connection draining, this keeps target
  # capacity serving throughout the rollout.
  update_policy {
    type                         = "PROACTIVE"
    minimal_action               = "REPLACE"
    max_surge_fixed              = length(var.zones)
    max_unavailable_fixed        = 0
    instance_redistribution_type = "PROACTIVE"
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
    create_before_destroy = true

    precondition {
      condition = var.disable_billing || nonsensitive(
        var.paddle_api_key != "" && var.paddle_webhook_secret != "" && var.paddle_client_token != ""
      )
      error_message = "Billing is enabled (disable_billing = false) but paddle_api_key / paddle_webhook_secret / paddle_client_token are not all set in the TFC workspace. Set all three, or set disable_billing = true to ship the Paddle stub."
    }

  }

  # Runtime boot prerequisites: without explicit edges the MIG can come up before
  # NAT / firewall / IAM / the database converge, so instances fail to pull the
  # image, read secrets, migrate, or pass its health probes.
  depends_on = [
    google_project_service.apis,
    google_compute_router_nat.emisar,
    google_compute_firewall.lb_to_app,
    google_compute_firewall.cluster_dist,
    google_secret_manager_secret_version.secret_key_base,
    google_sql_database.emisar,
    google_secret_manager_secret_version.release_cookie,
    google_secret_manager_secret_version.optional,
    google_sql_user.pgaudit_owner,
    google_sql_user.emisar_vm,
  ]
}
