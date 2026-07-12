# ── Secret Manager: every runtime secret the portal reads ────────────────────
# Value flow: Terraform Cloud workspace variables (SENSITIVE) → the secret
# versions below → cloud-init fetches each at boot over the metadata token. One
# place to set credentials (the TFC workspace), and a single apply stands the
# whole stack up — no out-of-band `gcloud secrets versions add` step. The
# Write-only provider arguments keep payloads out of new Terraform state. The
# external values still live in sensitive TFC workspace variables, so workspace
# access remains production access (see main.tf). Increment secret_generation
# whenever any supplied value changes; write-only values cannot diff themselves.
#
# Machine-generated secrets are not variables at all: SECRET_KEY_BASE is created
# here (random_password) and DATABASE_URL is assembled in db.tf — no human ever
# needs either value. An optional secret left "" in TFC gets NO version, so
# cloud-init skips its env var and the release treats the feature as off
# (runtime.exs); Paddle completeness is enforced at plan time in compute.tf.
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

  # Externally-issued credentials, one TFC workspace variable each.
  optional_secret_values = {
    "emisar-paddle-api-key"          = var.paddle_api_key
    "emisar-paddle-webhook-secret"   = var.paddle_webhook_secret
    "emisar-paddle-client-token"     = var.paddle_client_token
    "emisar-postmark-api-token"      = var.postmark_api_token
    "emisar-postmark-webhook-secret" = var.postmark_webhook_secret
    "emisar-sentry-dsn"              = var.sentry_dsn
    "emisar-mixpanel-token"          = var.mixpanel_token
  }

  # for_each keys must not derive from sensitive values; whether a secret is SET
  # is not itself secret, so unwrap just that boolean with nonsensitive().
  # Known only in REMOTE runs: local operations (terraform import/console) see
  # remote sensitive variables as unavailable, so they must pass dummy values,
  # e.g. `-var paddle_api_key=x` for each — the values never leave the machine.
  populated_optional_secrets = [
    for id, value in local.optional_secret_values : id if nonsensitive(value != "")
  ]
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
# project-wide secret role. Iterates the STATIC key map (not the resource map),
# so instance keys resolve in every context — a for_each over the resource map
# is "known only after apply" during a local import and hard-errors.
resource "google_secret_manager_secret_iam_member" "vm_access" {
  for_each  = local.app_secrets
  secret_id = google_secret_manager_secret.app[each.key].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.vm.email}"
}

# Phoenix's signing/encryption root — same length bar as `mix phx.gen.secret`.
# Alphanumeric only so it survives every quoting context it passes through.
ephemeral "random_password" "secret_key_base" {
  length  = 64
  special = false
}

resource "google_secret_manager_secret_version" "secret_key_base" {
  secret                 = google_secret_manager_secret.app["emisar-secret-key-base"].id
  secret_data_wo         = ephemeral.random_password.secret_key_base.result
  secret_data_wo_version = var.secret_generation
}

resource "google_secret_manager_secret_version" "optional" {
  for_each               = toset(local.populated_optional_secrets)
  secret                 = google_secret_manager_secret.app[each.key].id
  secret_data_wo         = local.optional_secret_values[each.key]
  secret_data_wo_version = var.secret_generation
}
