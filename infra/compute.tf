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
  #     --signer-workflow AndrewDryga/emisar/.github/workflows/runner-release-trusted.yml \
  #     --signer-digest <trusted_job_workflow_sha from github_oidc.tf>
  #
  # (the owner casing is the certificate's, not the lowercase repo spelling; the
  # attesting job runs inside the -trusted reusable workflow, so that ref — not
  # the thin runner-release.yml caller — is what the certificate SAN carries.
  # The --signer-digest is the reviewed trusted_job_workflow_sha in
  # github_oidc.tf; read it from there rather than pinning a copy that rots.)
  # That is what makes the pin a reviewed decision rather than a checksum
  # chasing whatever the release currently holds.
  # runtime/admin-runner/runner-version.txt and pack-pins.txt are the single
  # sources: tests/render and the infra gate read the same files, so a bump
  # is validated everywhere and cannot drift between copies.
  admin_runner_version = trimspace(file("${path.module}/runtime/admin-runner/runner-version.txt"))
  # The verified runner bundle is the offline bootstrap; these immutable
  # registry refs are the authoritative set reconciled on every service start.
  admin_runner_pack_pins = join("\n", [
    for line in split("\n", trimspace(file("${path.module}/runtime/admin-runner/pack-pins.txt"))) :
    line if line != "" && !startswith(line, "#")
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
    container_image      = var.container_image
    project_id           = var.project_id
    domain               = var.domain
    app_port             = local.portal_port
    mailer_from_email    = var.mailer_from_email
    cluster_value        = "emisar"
    disable_billing      = var.disable_billing
    runtime_secrets      = local.runtime_secrets
    database_user        = trimsuffix(google_service_account.vm.email, ".gserviceaccount.com")
    database_name        = google_sql_database.emisar.name
    database_role        = "emisar_owner"
    database_pool_size   = local.portal_database_pool_size
    release_cookie_ready = var.release_cookie_ready
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
# The pre-v1 directory-group migration changes the identity an authorization
# mapping follows. An old Portal process serving beside the migrated schema can
# regrant a deleted/recreated group, so this exceptional cutover drains the MIG
# before Terraform may restore it. The timestamp deliberately re-runs the proof
# on every attested apply: a retry after a partial restore must see the new
# instances and fail closed instead of trusting a barrier recorded in state.
resource "terraform_data" "directory_group_cutover_empty" {
  input = var.directory_group_cutover_ready
  triggers_replace = [
    var.directory_group_cutover_ready ? timestamp() : "inactive",
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail

      [ "$CUTOVER_READY" = true ] || exit 0

      for tool in curl grep mktemp seq sleep tr wc; do
        command -v "$tool" >/dev/null || {
          echo "directory-group cutover check requires $tool" >&2
          exit 1
        }
      done

      url="https://compute.googleapis.com/compute/v1/projects/$PROJECT_ID/regions/$REGION/instanceGroupManagers/$INSTANCE_GROUP/listManagedInstances"
      response_file=$(mktemp)
      trap 'rm -f "$response_file"' EXIT

      for attempt in $(seq 1 60); do
        if ! status=$(curl --silent --show-error \
          --connect-timeout 5 --max-time 30 --output "$response_file" \
          --write-out '%%{http_code}' \
          -X POST \
          -H "Authorization: Bearer $ACCESS_TOKEN" \
          -H "Content-Type: application/json" \
          --data '{}' \
          "$url"); then
          echo "managed-instance inventory failed on attempt $attempt" >&2
          exit 1
        fi

        case "$status" in
          200) ;;
          429|5??)
            sleep 10
            continue
            ;;
          401|403)
            echo "managed-instance inventory authentication was rejected with HTTP $status" >&2
            exit 1
            ;;
          *)
            echo "managed-instance inventory returned unexpected HTTP $status" >&2
            exit 1
            ;;
        esac

        remaining=$(tr -d '[:space:]' < "$response_file" | \
          grep -o '"instance":' | wc -l | tr -d ' ') || remaining=0

        if [ "$remaining" -eq 0 ]; then
          echo "directory-group cutover confirmed an empty Portal MIG"
          exit 0
        fi

        echo "directory-group cutover still sees $remaining managed instance(s); waiting" >&2
        sleep 10
      done

      echo "Portal MIG did not become empty within 10 minutes" >&2
      exit 1
    EOT

    environment = {
      ACCESS_TOKEN   = ephemeral.google_client_config.current.access_token
      CUTOVER_READY  = tostring(var.directory_group_cutover_ready)
      INSTANCE_GROUP = "emisar"
      PROJECT_ID     = var.project_id
      REGION         = var.region
    }
  }
}

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
    terraform_data.directory_group_cutover_empty,
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
