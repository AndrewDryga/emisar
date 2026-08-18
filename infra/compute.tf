locals {
  cloud_sql_proxy_image = "gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.23.0@sha256:54e23cad9aeeedbf88ab75f993146631b878035f702b31c51885a932e0c7286c"
  gcloud_image          = "gcr.io/google.com/cloudsdktool/google-cloud-cli:578.0.0-stable@sha256:39f4c48c083fb1d8d182eedc7de97545980afb646b1afdfec61a3f560969bc96"
  # Boot verifies this release against SHA256SUMS from the same release, which
  # proves the bytes match a list published beside them and nothing about who
  # built either. The Sigstore provenance that does prove it cannot be checked
  # on COS — there is no gh or cosign and no package manager to add one — so the
  # signature check happens HERE, when a human changes this value, not at boot:
  #
  #   gh attestation verify emisar-<version>-linux-amd64.tar.gz \
  #     --repo andrewdryga/emisar \
  #     --signer-workflow AndrewDryga/emisar/.github/workflows/runner-release.yml
  #
  # (the owner casing is the certificate's, not the lowercase repo spelling).
  # That is what makes the pin a reviewed decision rather than a checksum
  # chasing whatever the release currently holds.
  admin_runner_version = "0.20.1"
  # The verified runner bundle is the offline bootstrap; these immutable
  # registry refs are the authoritative set reconciled on every service start.
  admin_runner_public_packs = {
    cloud-init         = { version = "0.1.12", hash = "sha256:d1225d74b75cf2bffb6ff61cb832a3086c3f23f66776b4d7138aa37776171222" }
    debugging          = { version = "0.2.17", hash = "sha256:cfc2f6aa83108c16bb2256f79dd01cbd03c068c686f5d6ca8749882084b19775" }
    docker             = { version = "0.2.17", hash = "sha256:f09ebfe9b5da673ecbfadd4d2d8a77b1ad2ec9af951c8c58ebeaaca21bdc0852" }
    elixir-beam        = { version = "0.1.4", hash = "sha256:d47cc9856e3585b20564a245d0d508237f2f5378684e7ba190db43473ebd6acd" }
    gcp-certificates   = { version = "0.1.0", hash = "sha256:da73325336f2d11cdff984948bf6f53fe34f43f1bce873c6e01e6a6fc38f792b" }
    gcp-cloudsql       = { version = "0.3.0", hash = "sha256:45cbc52c0088f28a747d80cb2c71879232cb97e95aab65e15efcdd4840c30b32" }
    gcp-compute        = { version = "0.2.0", hash = "sha256:8df5c0c0c759c0a491435e39bb00f91371f2711d54334a3114c097ad21c2c2b2" }
    gcp-dns            = { version = "0.2.0", hash = "sha256:4163dda5066fe4553d38a94d9b1f8eca62595cf7246ee3ef7900de57251ad99b" }
    gcp-iam            = { version = "0.1.0", hash = "sha256:c8bc2db792a56ae123ea865287e029a0ecf6e95e5790722dcae3ff01449d480b" }
    gcp-load-balancing = { version = "0.1.0", hash = "sha256:d43b24b0767cb62752eb368314fec257755880f6ea860c453a76bf8c3ca5820b" }
    gcp-monitoring     = { version = "0.3.0", hash = "sha256:943bca4673613766ba4ccb593673ffda5d33a91a925aca6d1c02fc1232886c48" }
    gcp-networking     = { version = "0.1.0", hash = "sha256:8aeca131aa12cc7ee244a1c5bb7663a7434919e7f8a8406cd9206d0b9b02062f" }
    gcp-storage        = { version = "0.1.0", hash = "sha256:976ede94963f134ef0cca63eedd4bdb2dedde67d8e820feceac5a5a9c79a306b" }
    hcp-terraform      = { version = "0.8.0", hash = "sha256:5d753dced1595977ce9ec640dea0b26057ce95d38a6dfbcc27b3a0f4e4fc2592" }
    linux-core         = { version = "0.4.1", hash = "sha256:a5852885bec7b265c98bc897b6c45448d88c3cc92b098cd3d221b4c98e20edd4" }
    nic                = { version = "0.1.1", hash = "sha256:fe4e1d8a7e8633d57d95197103c8260d7b1273106595bae24c70efcacf65956d" }
    sentry             = { version = "0.1.0", hash = "sha256:8a33af4a63e08318ed0aad6afefbd3f5a1c84f9636e7a0de1f6a1ad902ef18ee" }
    systemd-deep       = { version = "0.1.15", hash = "sha256:a39bcb7a8172275a5870bf1e69ee4c13b7289f36312a66778d231368e9afdfcd" }
    time-sync          = { version = "0.1.9", hash = "sha256:717e790d5496ff76f9f5dad8fdb05aa08b476147d8e52a9a18579e14cf27f9b3" }
  }
  admin_runner_pack_pins = join("\n", [
    for id, pin in local.admin_runner_public_packs : "${id}=${pin.version}|${pin.hash}"
  ])
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
  # A five-connection pool per VM leaves room on the deployed tier for Cloud SQL
  # internals and for old + new fleets to overlap during a create-before-destroy
  # MIG replacement or multi-zone surge. (Sizing is a workspace variable — do
  # not restate the tier here; this repository is public.)
  portal_database_pool_size = 5
  # Connections the tier must keep for principals other than the portal pool: Cloud
  # SQL's superuser reserve, the pgaudit_owner / operator / livebook admin logins,
  # and the per-VM migration-on-boot connection. Held as headroom so a rollout surge
  # can't exhaust max_connections (see the MIG connection-ceiling precondition).
  db_connection_reserve = 15
  ensure_image_script = templatefile("${path.module}/runtime/portal/ensure-image.sh", {
    container_image       = var.container_image
    cloud_sql_proxy_image = local.cloud_sql_proxy_image
    gcloud_image          = local.gcloud_image
  })
  start_script = templatefile("${path.module}/runtime/portal/start.sh", {
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
  admin_runner_config = templatefile("${path.module}/runtime/admin-runner/config.yaml", {
    domain = var.domain
  })
  admin_runner_start_script = templatefile("${path.module}/runtime/admin-runner/start.sh", {
    project_id                = var.project_id
    runner_version            = local.admin_runner_version
    enrollment_secret_version = google_secret_manager_secret_version.admin_runner_enrollment_key.version
    tfe_secret_version        = google_secret_manager_secret_version.admin_runner_tfe_token.version
    sentry_secret_version     = google_secret_manager_secret_version.admin_runner_sentry_token.version
    pinned_packs              = local.admin_runner_pack_pins
  })
  admin_runner_gcloud_script = templatefile("${path.module}/runtime/admin-runner/gcloud.sh", {
    gcloud_image = local.gcloud_image
  })
  admin_runner_beam_script = file("${path.module}/runtime/admin-runner/beam.sh")
  admin_runner_pack_files = {
    for relative_path in fileset("${path.module}/packs/emisar-admin", "**") :
    "emisar-admin/${relative_path}" => filebase64("${path.module}/packs/emisar-admin/${relative_path}")
  }
  cloud_init = templatefile("${path.module}/runtime/portal/cloud-init.yaml", {
    container_image            = var.container_image
    cloud_sql_proxy_image      = local.cloud_sql_proxy_image
    app_port                   = local.portal_port
    database_connection_name   = google_sql_database_instance.emisar.connection_name
    ensure_image_script        = local.ensure_image_script
    start_script               = local.start_script
    admin_runner_config        = local.admin_runner_config
    admin_runner_start_script  = local.admin_runner_start_script
    admin_runner_gcloud_script = local.admin_runner_gcloud_script
    admin_runner_beam_script   = local.admin_runner_beam_script
    admin_runner_pack_files    = local.admin_runner_pack_files
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
  name = "emisar-${each.key}-${var.machine_type}"
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
  target_size = var.database_owner_role_ready ? var.instance_count : 0
  # Prefer available capacity within the selected zones. Zonal scarcity may
  # temporarily leave the fleet uneven instead of pinning a rollout to a full zone.
  distribution_policy_target_shape = "BALANCED"
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

  # A dry zone must not pin a rollout. Create-before-destroy leaves the surge no
  # reserved slot to take — its predecessor still holds it — so without this the
  # group retries the same exhausted zone for hours while every apply fails on
  # the wait_for_instances timeout. Alternate-zone repair requires update on
  # repair, and is unsupported on EVEN / ANY_SINGLE_ZONE shapes or a stateful
  # group, so the BALANCED shape above is load-bearing here. Nothing
  # redistributes afterwards (instance_redistribution_type is NONE), so a rollout
  # through a dry zone can leave the fleet lopsided until the next one.
  instance_lifecycle_policy {
    force_update_on_repair = "YES"

    on_repair {
      allow_changing_zone = "YES"
    }
  }

  # Create healthy replacements before removing old VMs. The per-zone surge may
  # temporarily exceed the configured target; BALANCED placement can use
  # whichever selected zone has capacity.
  update_policy {
    type                         = "PROACTIVE"
    minimal_action               = "REPLACE"
    max_surge_fixed              = length(var.zones)
    max_unavailable_fixed        = 0
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
    create_before_destroy = true

    precondition {
      condition = var.disable_billing || nonsensitive(
        var.paddle_api_key != "" && var.paddle_webhook_secret != "" && var.paddle_client_token != ""
      )
      error_message = "Billing is enabled (disable_billing = false) but paddle_api_key / paddle_webhook_secret / paddle_client_token are not all set in the TFC workspace. Set all three, or set disable_billing = true to ship the Paddle stub."
    }

    # Guard the DB connection ceiling against fleet growth: a create-before-destroy
    # rollout transiently runs the steady fleet PLUS one surge VM per zone, each
    # opening up to portal_database_pool_size Ecto connections. Keep that peak draw
    # plus the admin/system reserve within the tier's max_connections, or a raised
    # instance_count or pool silently exhausts connections mid-deploy. Move to a
    # larger db_tier and set db_max_connections to its SHOW max_connections first.
    precondition {
      condition     = ((var.instance_count + length(var.zones)) * local.portal_database_pool_size + local.db_connection_reserve) <= var.db_max_connections
      error_message = "Portal fleet DB connections would exceed the tier ceiling: rollout-peak (instance_count + zones) * pool_size (${local.portal_database_pool_size}) + reserve (${local.db_connection_reserve}) must stay within db_max_connections (${var.db_max_connections}). Lower instance_count or the pool, or move to a larger db_tier and set db_max_connections to its SHOW max_connections."
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
    google_secret_manager_secret_version.admin_runner_enrollment_key,
    google_secret_manager_secret_version.admin_runner_tfe_token,
    google_sql_user.pgaudit_owner,
    google_sql_user.emisar_vm,
  ]
}
