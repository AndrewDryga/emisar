# ── Cloud SQL for PostgreSQL — the portal's database ─────────────────────────
# onlytty is DB-less; emisar is a control plane with real state, so this is the
# central emisar-specific addition. SOC 2 posture:
#   • PRIVATE IP only (no public surface) — reachable solely over the VPC peering.
#   • Availability per var.db_availability_type (workspace-set): REGIONAL runs a
#     synchronous standby with automatic failover; ZONAL relies on backups/PITR.
#   • Automated backups + point-in-time recovery — durability / DR (RPO minutes).
#   • Encryption in transit required (ENCRYPTED_ONLY) and at rest (Google-managed;
#     swap in CMEK via `encryption_key_name` if key custody is required).
#   • deletion_protection so the production database can't be torn down by accident.
resource "google_sql_database_instance" "emisar" {
  name   = "emisar"
  region = var.region
  # Latest Cloud SQL major (GA and Cloud SQL's default since late 2025). Bump as
  # new majors go GA — it's a deliberate in-place major upgrade with a maintenance
  # window, never an edit-and-forget.
  database_version = "POSTGRES_18"

  # Guards `terraform destroy` / a destructive replacement at the API level, on top
  # of the Terraform lifecycle guard below.
  deletion_protection = true

  settings {
    # Pinned: left unset, Postgres 18 instances default to ENTERPRISE_PLUS,
    # which only accepts db-perf-optimized-N-* tiers — the create then 400s on
    # any shared-core or db-custom tier. ENTERPRISE covers our whole tier dial;
    # moving to Plus is a deliberate edition+tier change, not a default.
    edition           = "ENTERPRISE"
    tier              = var.db_tier
    availability_type = var.db_availability_type
    disk_type         = "PD_SSD"
    disk_size         = var.db_disk_size_gb
    disk_autoresize   = true

    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.emisar.id
      ssl_mode        = "ENCRYPTED_ONLY"
    }

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
      start_time                     = "03:00"
      transaction_log_retention_days = 7
      backup_retention_settings {
        retained_backups = 30
        retention_unit   = "COUNT"
      }
    }

    maintenance_window {
      day          = 7 # Sunday
      hour         = 4
      update_track = "stable"
    }

    insights_config {
      # Shared-core tiers don't support Query Insights; enabled automatically on
      # db-custom-* tiers.
      query_insights_enabled = startswith(var.db_tier, "db-custom-")
    }

    database_flags {
      name  = "log_min_duration_statement"
      value = "1000" # log statements slower than 1s (perf + audit signal)
    }
  }

  # Private IP requires the service-networking peering to exist first.
  depends_on = [
    google_service_networking_connection.private_service,
    google_project_service.apis,
  ]

  lifecycle {
    prevent_destroy = true

    # Catch the invalid combo at plan time, not after a ten-minute create attempt.
    precondition {
      condition     = var.db_availability_type == "ZONAL" || startswith(var.db_tier, "db-custom-")
      error_message = "REGIONAL HA requires a db-custom-* db_tier — shared-core tiers (db-f1-micro / db-g1-small) are ZONAL-only."
    }
  }
}

resource "google_sql_database" "emisar" {
  name     = "emisar"
  instance = google_sql_database_instance.emisar.name
}

# App DB credential. Generated here (so a single apply stands the stack up) and
# stored in Secret Manager. It lands in TF state — consistent with the decision
# that secrets live in the Terraform Cloud workspace (vars + state, RBAC-gated);
# the harder hardening is Cloud SQL IAM auth (no password) via the Auth Proxy,
# noted in COMPLIANCE.md. Alphanumeric so it needs no URL-encoding in the URL.
resource "random_password" "db" {
  length  = 32
  special = false
}

resource "google_sql_user" "emisar" {
  name     = "emisar"
  instance = google_sql_database_instance.emisar.name
  password = random_password.db.result
}

# DATABASE_URL the release reads (the secret CONTAINER is declared in secrets.tf;
# this fills its value from the private IP + generated password). SSL is required
# by the instance and switched on in the release via DATABASE_SSL=1 (compute.tf).
resource "google_secret_manager_secret_version" "database_url" {
  secret = google_secret_manager_secret.app["emisar-database-url"].id
  secret_data = format(
    "ecto://%s:%s@%s/%s",
    google_sql_user.emisar.name,
    random_password.db.result,
    google_sql_database_instance.emisar.private_ip_address,
    google_sql_database.emisar.name,
  )
}
