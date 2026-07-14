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

  ensure_image = templatefile("${path.module}/../../templates/ensure-image.sh", {
    container_image       = local.common.container_image
    cloud_sql_proxy_image = local.common.cloud_sql_proxy_image
  })

  start = templatefile("${path.module}/../../templates/start.sh", merge(local.common, {
    release_cookie_ready = true
    runtime_secrets = merge(local.common.runtime_secrets, {
      "emisar-release-cookie" = { env_name = "RELEASE_COOKIE", version = "1" }
    })
  }))

  cloud_init = templatefile("${path.module}/../../templates/cloud-init.yaml", {
    ensure_image_script      = local.ensure_image
    start_script             = local.start
    container_image          = local.common.container_image
    cloud_sql_proxy_image    = local.common.cloud_sql_proxy_image
    database_connection_name = local.common.database_connection_name
    app_port                 = local.common.app_port
  })
}

output "cloud_init" {
  value = local.cloud_init
}
