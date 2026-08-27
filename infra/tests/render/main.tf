locals {
  common = {
    project_id               = "test-project"
    domain                   = "example.test"
    mailer_from_email        = "hello@example.test"
    app_port                 = 4000
    container_image          = "ghcr.io/andrewdryga/emisar@sha256:0000000000000000000000000000000000000000000000000000000000000000"
    cloud_sql_proxy_image    = "gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.23.0@sha256:54e23cad9aeeedbf88ab75f993146631b878035f702b31c51885a932e0c7286c"
    gcloud_image             = "gcr.io/google.com/cloudsdktool/google-cloud-cli:578.0.0-stable@sha256:39f4c48c083fb1d8d182eedc7de97545980afb646b1afdfec61a3f560969bc96"
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

  ensure_image = templatefile("${path.module}/../../runtime/portal/ensure-image.sh", {
    container_image       = local.common.container_image
    cloud_sql_proxy_image = local.common.cloud_sql_proxy_image
    gcloud_image          = local.common.gcloud_image
  })

  start = templatefile("${path.module}/../../runtime/portal/start.sh", merge(local.common, {
    release_cookie_ready = true
    runtime_secrets = merge(local.common.runtime_secrets, {
      "emisar-release-cookie" = { env_name = "RELEASE_COOKIE", version = "1" }
    })
  }))

  admin_runner_config = templatefile("${path.module}/../../runtime/admin-runner/config.yaml", {
    domain = local.common.domain
  })

  admin_runner_start = templatefile("${path.module}/../../runtime/admin-runner/start.sh", {
    project_id                = local.common.project_id
    runner_version            = trimspace(file("${path.module}/../../runtime/admin-runner/runner-version.txt"))
    enrollment_secret_version = "1"
    tfe_secret_version        = "2"
    sentry_secret_version     = "3"
    pinned_packs = join("\n", [
      for line in split("\n", trimspace(file("${path.module}/../../runtime/admin-runner/pack-pins.txt"))) :
      line if line != "" && !startswith(line, "#")
    ])
  })

  admin_runner_gcloud = templatefile("${path.module}/../../runtime/admin-runner/gcloud.sh", {
    gcloud_image = local.common.gcloud_image
  })
  admin_runner_beam = file("${path.module}/../../runtime/admin-runner/beam.sh")

  admin_runner_pack_files = {
    for relative_path in fileset("${path.module}/../../packs/emisar-admin", "**") :
    "emisar-admin/${relative_path}" => filebase64("${path.module}/../../packs/emisar-admin/${relative_path}")
  }

  cloud_init = templatefile("${path.module}/../../runtime/portal/cloud-init.yaml", {
    ensure_image_script        = local.ensure_image
    start_script               = local.start
    admin_runner_config        = local.admin_runner_config
    admin_runner_start_script  = local.admin_runner_start
    admin_runner_gcloud_script = local.admin_runner_gcloud
    admin_runner_beam_script   = local.admin_runner_beam
    admin_runner_pack_files    = local.admin_runner_pack_files
    cloud_sql_proxy_image      = local.common.cloud_sql_proxy_image
    database_connection_name   = local.common.database_connection_name
    app_port                   = local.common.app_port
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

  livebook_ensure_images = templatefile("${path.module}/../../runtime/livebook/ensure-images.sh", {
    livebook_image        = local.livebook.livebook_image
    cloud_sql_proxy_image = local.livebook.cloud_sql_proxy_image
  })

  livebook_start = templatefile("${path.module}/../../runtime/livebook/start.sh", {
    for key, value in local.livebook : key => value if key != "database_connection_name"
  })

  livebook_cluster_nodes = templatefile("${path.module}/../../runtime/livebook/cluster-nodes.sh", {
    project_id = local.livebook.project_id
  })

  livebook_cloud_init = templatefile("${path.module}/../../runtime/livebook/cloud-init.yaml", {
    cloud_sql_proxy_image             = local.livebook.cloud_sql_proxy_image
    livebook_port                     = local.livebook.livebook_port
    database_connection_name          = local.livebook.database_connection_name
    livebook_ensure_images_script     = local.livebook_ensure_images
    livebook_prepare_data_script      = file("${path.module}/../../runtime/livebook/prepare-data.sh")
    livebook_product_analytics_script = file("${path.module}/../../runtime/livebook/product-analytics.exs")
    livebook_cluster_nodes_script     = local.livebook_cluster_nodes
    livebook_start_script             = local.livebook_start
    livebook_notebooks = {
      for notebook in fileset("${path.module}/../../runtime/livebook/notebooks", "*.livemd") :
      notebook => file("${path.module}/../../runtime/livebook/notebooks/${notebook}")
    }
  })
}

output "cloud_init" {
  value = local.cloud_init
}

output "livebook_cloud_init" {
  value = local.livebook_cloud_init
}
