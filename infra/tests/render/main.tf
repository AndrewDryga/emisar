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

  livebook = {
    project_id                    = "test-project"
    project_number                = "123456789"
    domain                        = "example.test"
    livebook_image                = "ghcr.io/livebook-dev/livebook:0.19.8@sha256:38eed8467d3df794dd36cbe722768e46d709b02e00368e0a06aa7508220a8763"
    cloud_sql_proxy_image         = local.common.cloud_sql_proxy_image
    livebook_port                 = 8080
    livebook_backend_name         = "emisar-livebook-backend"
    livebook_secret_version       = "1"
    release_cookie_version        = "1"
    database_user                 = "emisar-livebook@test-project.iam"
    database_user_uri             = "emisar-livebook%40test-project.iam"
    database_name                 = "emisar"
    database_role                 = "emisar_owner"
    database_statement_timeout_ms = 30000
    database_connection_name      = "test-project:us-central1:emisar"
  }

  livebook_ensure_images = templatefile("${path.module}/../../templates/livebook-ensure-images.sh", {
    livebook_image        = local.livebook.livebook_image
    cloud_sql_proxy_image = local.livebook.cloud_sql_proxy_image
  })

  livebook_start = templatefile("${path.module}/../../templates/start-livebook.sh", {
    for key, value in local.livebook : key => value if key != "database_connection_name"
  })

  livebook_cluster_nodes = templatefile("${path.module}/../../templates/livebook-cluster-nodes.sh", {
    project_id = local.livebook.project_id
  })

  livebook_cloud_init = templatefile("${path.module}/../../templates/livebook-cloud-init.yaml", {
    cloud_sql_proxy_image             = local.livebook.cloud_sql_proxy_image
    livebook_port                     = local.livebook.livebook_port
    database_connection_name          = local.livebook.database_connection_name
    livebook_ensure_images_script     = local.livebook_ensure_images
    livebook_prepare_data_script      = file("${path.module}/../../templates/livebook-prepare-data.sh")
    livebook_product_analytics_script = file("${path.module}/../../livebook/product_analytics.exs")
    livebook_cluster_nodes_script     = local.livebook_cluster_nodes
    livebook_start_script             = local.livebook_start
    livebook_notebooks = {
      for notebook in fileset("${path.module}/../../livebook/notebooks", "*.livemd") :
      notebook => file("${path.module}/../../livebook/notebooks/${notebook}")
    }
  })
}

output "cloud_init" {
  value = local.cloud_init
}

output "livebook_cloud_init" {
  value = local.livebook_cloud_init
}
