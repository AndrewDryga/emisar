# ── Secret Manager: every runtime secret the portal reads ────────────────────
# Containers are created here; VALUES are added out-of-band (see README) so they
# never live in Terraform state — EXCEPT database-url, which db.tf fills from the
# Cloud SQL instance it creates. cloud-init fetches each at boot over the metadata
# token and exports only the ones with a non-empty version, so an unpopulated
# optional is simply unset and the release treats it as "feature off"
# (runtime.exs). Required for a prod boot: secret-key-base, database-url, and the
# three paddle-* (or set EMISAR_DISABLE_BILLING=1 in the instance template).
locals {
  app_secrets = {
    "emisar-secret-key-base"         = "SECRET_KEY_BASE"
    "emisar-database-url"            = "DATABASE_URL"
    "emisar-paddle-api-key"          = "PADDLE_API_KEY"
    "emisar-paddle-webhook-secret"   = "PADDLE_WEBHOOK_SECRET"
    "emisar-paddle-client-token"     = "PADDLE_CLIENT_TOKEN"
    "emisar-postmark-api-token"      = "POSTMARK_API_TOKEN"
    "emisar-postmark-webhook-secret" = "POSTMARK_WEBHOOK_SECRET"
    "emisar-sentry-dsn"              = "SENTRY_DSN"
    "emisar-mixpanel-token"          = "MIXPANEL_TOKEN"
  }
}

resource "google_secret_manager_secret" "app" {
  for_each  = local.app_secrets
  secret_id = each.key

  replication {
    auto {}
  }

  depends_on = [google_project_service.apis]
}

# Least privilege: the VM SA gets accessor on exactly these secrets, not a
# project-wide secret role.
resource "google_secret_manager_secret_iam_member" "vm_access" {
  for_each  = google_secret_manager_secret.app
  secret_id = each.value.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.vm.email}"
}
