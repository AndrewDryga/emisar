locals {
  common = {
    project_id               = "test-project"
    domain                   = "example.test"
    mailer_from_email        = "hello@example.test"
    app_port                 = 4000
    container_image          = "ghcr.io/andrewdryga/emisar@sha256:0000000000000000000000000000000000000000000000000000000000000000"
    cloud_sql_proxy_image    = "gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.23.0@sha256:54e23cad9aeeedbf88ab75f993146631b878035f702b31c51885a932e0c7286c"
    cluster_value            = "emisar-portal"
    database_user            = "emisar-vm@test-project.iam"
    database_name            = "emisar"
    database_role            = "emisar_owner"
    database_pool_size       = 5
    disable_billing          = false
    database_connection_name = "test-project:us-central1:emisar"
    runtime_secrets = {
      "emisar-secret-key-base" = { env_name = "SECRET_KEY_BASE", version = "1" }
    }
  }

  ensure_image_iam = templatefile("${path.module}/../../templates/ensure-image.sh", {
    container_image       = local.common.container_image
    cloud_sql_proxy_image = local.common.cloud_sql_proxy_image
    database_auth_mode    = "iam"
  })
  ensure_image_password = templatefile("${path.module}/../../templates/ensure-image.sh", {
    container_image       = local.common.container_image
    cloud_sql_proxy_image = local.common.cloud_sql_proxy_image
    database_auth_mode    = "password"
  })

  start_iam = templatefile("${path.module}/../../templates/start.sh", merge(local.common, {
    database_auth_mode   = "iam"
    release_cookie_ready = true
    runtime_secrets = merge(local.common.runtime_secrets, {
      "emisar-release-cookie" = { env_name = "RELEASE_COOKIE", version = "1" }
    })
  }))
  start_password = templatefile("${path.module}/../../templates/start.sh", merge(local.common, {
    database_auth_mode   = "password"
    database_role        = ""
    release_cookie_ready = false
    runtime_secrets = merge(local.common.runtime_secrets, {
      "emisar-database-url" = { env_name = "DATABASE_URL", version = "1" }
    })
  }))

  cloud_init_iam = templatefile("${path.module}/../../templates/cloud-init.yaml", {
    database_auth_mode       = "iam"
    db_server_ca             = ""
    ensure_image_script      = local.ensure_image_iam
    start_script             = local.start_iam
    container_image          = local.common.container_image
    cloud_sql_proxy_image    = local.common.cloud_sql_proxy_image
    database_connection_name = local.common.database_connection_name
    app_port                 = local.common.app_port
  })
  cloud_init_password = templatefile("${path.module}/../../templates/cloud-init.yaml", {
    database_auth_mode       = "password"
    db_server_ca             = "-----BEGIN CERTIFICATE-----\ntest\n-----END CERTIFICATE-----"
    ensure_image_script      = local.ensure_image_password
    start_script             = local.start_password
    container_image          = local.common.container_image
    cloud_sql_proxy_image    = local.common.cloud_sql_proxy_image
    database_connection_name = local.common.database_connection_name
    app_port                 = local.common.app_port
  })
}

output "cloud_init_iam" {
  value = local.cloud_init_iam
}

output "cloud_init_password" {
  value = local.cloud_init_password
}
