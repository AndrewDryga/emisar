# ── Cloud SQL for PostgreSQL — the portal's database ─────────────────────────
# onlytty is DB-less; emisar is a control plane with real state, so this is the
# central emisar-specific addition. SOC 2 posture:
#   • PRIVATE IP only (no public surface) — reachable solely over the VPC peering.
#   • Intentionally ZONAL: recovery uses backups/PITR rather than paid HA.
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

  # Blocks Terraform-driven deletion; the API-level guard below separately blocks
  # direct gcloud/API deletion outside Terraform.
  deletion_protection = true

  settings {
    deletion_protection_enabled = true

    # Pinned: left unset, Postgres 18 instances default to ENTERPRISE_PLUS,
    # which only accepts db-perf-optimized-N-* tiers — the create then 400s on
    # any shared-core or db-custom tier. ENTERPRISE covers our whole tier dial;
    # moving to Plus is a deliberate edition+tier change, not a default.
    edition           = "ENTERPRISE"
    tier              = var.db_tier
    availability_type = "ZONAL"
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
      name  = "cloudsql.iam_authentication"
      value = "on"
    }

    database_flags {
      name  = "cloudsql.enable_pgaudit"
      value = "on"
    }

    # Only role + DDL are permitted in production; ordinary
    # SELECT/INSERT/UPDATE/DELETE traffic is deliberately excluded.
    database_flags {
      name  = "pgaudit.log"
      value = "role,ddl"
    }

    database_flags {
      name  = "pgaudit.log_parameter"
      value = "off"
    }
  }

  # Private IP requires the service-networking peering to exist first.
  depends_on = [
    google_service_networking_connection.private_service,
    google_project_service.apis,
  ]

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_sql_database" "emisar" {
  name     = "emisar"
  instance = google_sql_database_instance.emisar.name

  lifecycle {
    prevent_destroy = true
  }
}

# pgAudit creates superuser-only event triggers owned by the built-in Cloud SQL
# administrator. Keep that principal as their owner, but replace its old runtime
# password with an inaccessible apply-only value.
ephemeral "random_password" "pgaudit_owner" {
  length  = 64
  special = false
}

resource "google_sql_user" "pgaudit_owner" {
  name        = "emisar"
  instance    = google_sql_database_instance.emisar.name
  password_wo = ephemeral.random_password.pgaudit_owner.result
  # Increment in the reviewed apply that closes a blank-database bootstrap so
  # any temporary operator-known password is replaced before the fleet starts.
  password_wo_version = 2

  lifecycle {
    prevent_destroy = true
  }
}

# Terraform can create the Cloud SQL IAM principal, but PostgreSQL ownership is
# bootstrapped explicitly first (README.md). Deferring creation until that role
# exists avoids temporarily granting the application cloudsqlsuperuser.
resource "google_sql_user" "emisar_vm" {
  count          = var.database_owner_role_ready ? 1 : 0
  name           = trimsuffix(google_service_account.vm.email, ".gserviceaccount.com")
  instance       = google_sql_database_instance.emisar.name
  type           = "CLOUD_IAM_SERVICE_ACCOUNT"
  database_roles = ["emisar_owner"]

  lifecycle {
    prevent_destroy = true
  }
}
