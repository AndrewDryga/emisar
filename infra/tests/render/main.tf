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
    runner_version            = "0.17.2"
    enrollment_secret_version = "1"
    tfe_secret_version        = "2"
    pinned_packs = join("\n", [
      "cloud-init=0.1.11|sha256:b6fe92b1196b132b6abf815d2e6ddbe0e082738a1b69cd837355990b339943b6",
      "debugging=0.2.15|sha256:a36c3bbd405db33b805afbd0c03cc418e3716ae2218873d3569b2c3339bc513f",
      "docker=0.2.17|sha256:f09ebfe9b5da673ecbfadd4d2d8a77b1ad2ec9af951c8c58ebeaaca21bdc0852",
      "elixir-beam=0.1.4|sha256:d47cc9856e3585b20564a245d0d508237f2f5378684e7ba190db43473ebd6acd",
      "firewall=0.1.12|sha256:0c7b40d32bb0ac8e6e017773d49c840d75566e710678bcdb5e50a7170074d854",
      "gcp-certificates=0.1.0|sha256:da73325336f2d11cdff984948bf6f53fe34f43f1bce873c6e01e6a6fc38f792b",
      "gcp-cloudsql=0.3.0|sha256:45cbc52c0088f28a747d80cb2c71879232cb97e95aab65e15efcdd4840c30b32",
      "gcp-compute=0.2.0|sha256:8df5c0c0c759c0a491435e39bb00f91371f2711d54334a3114c097ad21c2c2b2",
      "gcp-dns=0.2.0|sha256:4163dda5066fe4553d38a94d9b1f8eca62595cf7246ee3ef7900de57251ad99b",
      "gcp-iam=0.1.0|sha256:c8bc2db792a56ae123ea865287e029a0ecf6e95e5790722dcae3ff01449d480b",
      "gcp-load-balancing=0.1.0|sha256:d43b24b0767cb62752eb368314fec257755880f6ea860c453a76bf8c3ca5820b",
      "gcp-monitoring=0.2.0|sha256:ab13b607bfdfc3583249d0c06a53daa06c3ed1c012aeaa97563f961bf33d892d",
      "gcp-networking=0.1.0|sha256:8aeca131aa12cc7ee244a1c5bb7663a7434919e7f8a8406cd9206d0b9b02062f",
      "gcp-storage=0.1.0|sha256:976ede94963f134ef0cca63eedd4bdb2dedde67d8e820feceac5a5a9c79a306b",
      "hcp-terraform=0.6.4|sha256:c01e745b013ead4cd3b455a62874b20821d3a90d4b6f342c4f634be6be147ee6",
      "linux-core=0.3.23|sha256:8e65576b749b0698744f708e1827c82363098cb953fb39279b2a02034fc3e97c",
      "nic=0.1.1|sha256:fe4e1d8a7e8633d57d95197103c8260d7b1273106595bae24c70efcacf65956d",
      "systemd-deep=0.1.15|sha256:a39bcb7a8172275a5870bf1e69ee4c13b7289f36312a66778d231368e9afdfcd",
      "time-sync=0.1.8|sha256:fa271a412ac92244b3a80c2ec8586c0e49ff2da5e83be19f958d61c2b72772d2",
    ])
  })

  admin_runner_gcloud = templatefile("${path.module}/../../runtime/admin-runner/gcloud.sh", {
    gcloud_image = local.common.gcloud_image
  })

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
    admin_runner_pack_files    = local.admin_runner_pack_files
    container_image            = local.common.container_image
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
