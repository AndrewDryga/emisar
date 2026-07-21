# ── Secret Manager: every runtime secret the portal reads ────────────────────
# Value flow: Terraform Cloud workspace variables (SENSITIVE) → the secret
# versions below → cloud-init fetches each at boot over the metadata token. One
# place to set credentials (the TFC workspace), and a single apply stands the
# whole stack up — no out-of-band `gcloud secrets versions add` step. The
# Write-only provider arguments keep payloads out of new Terraform state. The
# external values still live in sensitive TFC workspace variables, so workspace
# access remains production access (see main.tf). These initial write-only
# versions are intentionally stable: a real rotation is a reviewed maintenance
# change to the affected credential, never a global infrastructure knob.
#
# SECRET_KEY_BASE is generated here rather than supplied by a human. An optional
# secret left "" in TFC gets NO version, so
# cloud-init skips its env var and the release treats the feature as off
# (runtime.exs); Paddle completeness is enforced at plan time in compute.tf.
locals {
  secret_definitions = {
    "emisar-secret-key-base"         = "SECRET_KEY_BASE"
    "emisar-release-cookie"          = "RELEASE_COOKIE"
    "emisar-database-url"            = "DATABASE_URL"
    "emisar-paddle-api-key"          = "PADDLE_API_KEY"
    "emisar-paddle-webhook-secret"   = "PADDLE_WEBHOOK_SECRET"
    "emisar-paddle-client-token"     = "PADDLE_CLIENT_TOKEN"
    "emisar-postmark-api-token"      = "POSTMARK_API_TOKEN"
    "emisar-postmark-webhook-secret" = "POSTMARK_WEBHOOK_SECRET"
    "emisar-sentry-dsn"              = "SENTRY_DSN"
    "emisar-mixpanel-token"          = "MIXPANEL_TOKEN"
  }

  app_secrets = {
    for id, env_name in local.secret_definitions : id => env_name
    if id != "emisar-database-url" && (id != "emisar-release-cookie" || var.release_cookie_ready)
  }

  # One deliberately edited generation per secret. Changing a generation writes
  # a new version for only that secret; its computed version is rendered into
  # cloud-init, so the instance template rolls and replacement VMs fetch exactly
  # the reviewed version rather than a mutable `latest` alias.
  secret_generations = {
    "emisar-secret-key-base"         = 1
    "emisar-release-cookie"          = 1
    "emisar-paddle-api-key"          = 1
    "emisar-paddle-webhook-secret"   = 1
    "emisar-paddle-client-token"     = 1
    "emisar-postmark-api-token"      = 1
    "emisar-postmark-webhook-secret" = 1
    "emisar-sentry-dsn"              = 1
    "emisar-mixpanel-token"          = 1
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

  # Intentionally absent optional capabilities never reach cloud-init. Every
  # rendered secret is therefore required: IAM, network, HTTP, and payload
  # failures stop the VM before it can become ready with degraded production
  # behavior hidden behind a fallback.
  mandatory_runtime_secrets = merge({
    "emisar-secret-key-base" = {
      env_name = "SECRET_KEY_BASE"
      version  = google_secret_manager_secret_version.secret_key_base.version
    }
    },
    var.release_cookie_ready ? {
      "emisar-release-cookie" = {
        env_name = "RELEASE_COOKIE"
        version  = google_secret_manager_secret_version.release_cookie[0].version
      }
    } : {},
  )

  optional_runtime_secrets = {
    for id in local.populated_optional_secrets : id => {
      env_name = local.app_secrets[id]
      version  = google_secret_manager_secret_version.optional[id].version
    }
  }

  runtime_secrets = merge(local.mandatory_runtime_secrets, local.optional_runtime_secrets)
}

resource "google_secret_manager_secret" "app" {
  for_each            = local.secret_definitions
  project             = var.project_id
  secret_id           = each.key
  deletion_protection = true

  replication {
    auto {}
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_iam_member" "vm_access" {
  # Keep the retired DATABASE_URL container to avoid destructive removal and
  # name reuse. Audit evidence lives independently in the locked logging bucket.
  for_each = {
    for id, env_name in local.secret_definitions : id => env_name
    if id != "emisar-database-url"
  }
  project   = var.project_id
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
  secret_data_wo_version = local.secret_generations["emisar-secret-key-base"]
  deletion_policy        = "ABANDON"
}

resource "google_secret_manager_secret" "admin_runner_enrollment_key" {
  project             = var.project_id
  secret_id           = "emisar-admin-runner-enrollment-key"
  deletion_protection = true

  replication {
    auto {}
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "admin_runner_enrollment_key" {
  secret         = google_secret_manager_secret.admin_runner_enrollment_key.id
  secret_data_wo = var.emisar_runner_enrollment_key
  # The provider requires a numeric trigger for write-only updates. Thirteen
  # hex digits stay exactly representable while making accidental reuse remote.
  secret_data_wo_version = nonsensitive(parseint(substr(sha256(var.emisar_runner_enrollment_key), 0, 13), 16))
  deletion_policy        = "ABANDON"
}

resource "google_secret_manager_secret_iam_member" "admin_runner_enrollment_key_access" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.admin_runner_enrollment_key.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.vm.email}"
}

resource "google_secret_manager_secret_version" "release_cookie" {
  count                  = var.release_cookie_ready || var.livebook_enabled ? 1 : 0
  secret                 = google_secret_manager_secret.app["emisar-release-cookie"].id
  secret_data_wo         = var.release_cookie_value
  secret_data_wo_version = local.secret_generations["emisar-release-cookie"]
  deletion_policy        = "ABANDON"
}

resource "google_secret_manager_secret_version" "optional" {
  for_each               = toset(local.populated_optional_secrets)
  secret                 = google_secret_manager_secret.app[each.key].id
  secret_data_wo         = local.optional_secret_values[each.key]
  secret_data_wo_version = local.secret_generations[each.key]
  deletion_policy        = "ABANDON"
}

# Livebook is a separate trust domain from the portal release: its session
# signing key is generated independently, while only the exact shared release
# cookie grants the explicitly requested production-node debugging capability.
resource "google_secret_manager_secret" "livebook_secret_key_base" {
  count = var.livebook_enabled ? 1 : 0

  project             = var.project_id
  secret_id           = "emisar-livebook-secret-key-base"
  deletion_protection = true

  replication {
    auto {}
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.apis]
}

ephemeral "random_password" "livebook_secret_key_base" {
  count = var.livebook_enabled ? 1 : 0

  length  = 64
  special = false
}

resource "google_secret_manager_secret_version" "livebook_secret_key_base" {
  count = var.livebook_enabled ? 1 : 0

  secret                 = google_secret_manager_secret.livebook_secret_key_base[0].id
  secret_data_wo         = ephemeral.random_password.livebook_secret_key_base[0].result
  secret_data_wo_version = 1
  deletion_policy        = "ABANDON"
}

resource "google_secret_manager_secret_iam_member" "livebook_secret_key_access" {
  count = var.livebook_enabled ? 1 : 0

  project   = var.project_id
  secret_id = google_secret_manager_secret.livebook_secret_key_base[0].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.livebook[0].email}"
}

resource "google_secret_manager_secret_iam_member" "livebook_release_cookie_access" {
  count = var.livebook_enabled ? 1 : 0

  project   = var.project_id
  secret_id = google_secret_manager_secret.app["emisar-release-cookie"].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.livebook[0].email}"
}
