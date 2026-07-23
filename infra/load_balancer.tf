# ── Global anycast IPs (IPv4 + IPv6) fronting the HTTPS load balancer ────────
resource "google_compute_global_address" "ipv4" {
  name       = "emisar-ipv4"
  ip_version = "IPV4"
  depends_on = [google_project_service.apis]
}

resource "google_compute_global_address" "ipv6" {
  name       = "emisar-ipv6"
  ip_version = "IPV6"
  depends_on = [google_project_service.apis]
}

resource "google_compute_health_check" "livebook" {
  count = var.livebook_enabled ? 1 : 0

  name                = "emisar-livebook-health"
  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3

  # Livebook deliberately leaves /public available for platform probes while
  # its signed-IAP identity provider protects every operator route.
  http_health_check {
    request_path = "/public/health"
    port         = local.livebook_port
  }

  depends_on = [google_project_service.apis]
}

resource "google_compute_backend_service" "livebook" {
  count = var.livebook_enabled ? 1 : 0

  name                            = local.livebook_backend_name
  load_balancing_scheme           = "EXTERNAL_MANAGED"
  protocol                        = "HTTP"
  port_name                       = "livebook"
  timeout_sec                     = var.backend_timeout_sec
  connection_draining_timeout_sec = 120
  health_checks                   = [google_compute_health_check.livebook[0].id]

  # Omitting OAuth credentials selects Google's managed browser client. IAP
  # authenticates the user; Livebook independently validates its signed JWT.
  iap {
    enabled = true
  }

  log_config {
    enable      = var.lb_request_log_sampling > 0
    sample_rate = var.lb_request_log_sampling
  }

  backend {
    group           = google_compute_instance_group.livebook[0].id
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }
}

# Livebook widgets execute on livebookusercontent.com and load short-lived,
# tokenized assets without the operator's IAP cookie. Only /public/* reaches
# this backend; the host's default backend remains IAP-protected.
resource "google_compute_backend_service" "livebook_public" {
  count = var.livebook_enabled ? 1 : 0

  name                            = local.livebook_public_backend_name
  load_balancing_scheme           = "EXTERNAL_MANAGED"
  protocol                        = "HTTP"
  port_name                       = "livebook"
  timeout_sec                     = var.backend_timeout_sec
  connection_draining_timeout_sec = 120
  health_checks                   = [google_compute_health_check.livebook[0].id]

  log_config {
    enable      = var.lb_request_log_sampling > 0
    sample_rate = var.lb_request_log_sampling
  }

  backend {
    group           = google_compute_instance_group.livebook[0].id
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }
}

resource "terraform_data" "livebook_backend_ready" {
  count = var.livebook_enabled ? 2 : 0

  triggers_replace = [
    count.index == 0 ?
    google_compute_backend_service.livebook[0].id :
    google_compute_backend_service.livebook_public[0].id
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail

      response_file=$(mktemp)
      trap 'rm -f "$response_file"' EXIT
      url="https://compute.googleapis.com/compute/v1/projects/$PROJECT_ID/global/backendServices/$BACKEND_SERVICE/getHealth"
      payload=$(printf '{"group":"%s"}' "$INSTANCE_GROUP")

      for _attempt in $(seq 1 60); do
        status=$(curl --silent --show-error --connect-timeout 5 --max-time 30 \
          --output "$response_file" --write-out '%%{http_code}' -X POST \
          -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" \
          --data "$payload" "$url" || true)

        if [ "$status" = 200 ] && tr -d '[:space:]' < "$response_file" | grep -q '"healthState":"HEALTHY"'; then
          exit 0
        fi
        case "$status" in
          200|429|5??) sleep 10 ;;
          *) echo "Livebook backend health returned HTTP $status" >&2; exit 1 ;;
        esac
      done

      echo "Livebook backend did not become healthy" >&2
      exit 1
    EOT

    environment = {
      ACCESS_TOKEN    = ephemeral.google_client_config.current.access_token
      BACKEND_SERVICE = count.index == 0 ? google_compute_backend_service.livebook[0].name : google_compute_backend_service.livebook_public[0].name
      INSTANCE_GROUP  = google_compute_instance_group.livebook[0].id
      PROJECT_ID      = var.project_id
    }
  }
}

# ── Backend: the MIG behind an HTTP backend service + health check ───────────
# Cloud CDN stays off (the console is authenticated + dynamic). Cloud Armor can
# attach here later via security_policy for WAF/rate-limiting.
resource "google_compute_backend_service" "app" {
  # A readiness-contract change gets a complete successor backend. The URL map
  # switches only after that backend passes the barrier below.
  name                            = "${google_compute_region_instance_group_manager.emisar.name}-${local.readiness_generation}-backend"
  load_balancing_scheme           = "EXTERNAL_MANAGED"
  protocol                        = "HTTP"
  port_name                       = "http"
  timeout_sec                     = var.backend_timeout_sec
  connection_draining_timeout_sec = 120
  health_checks                   = [google_compute_health_check.readiness.id]

  # Edge request log — the record of traffic the app never sees (probes, 502
  # windows, blocked paths, the client-IP chain). A cost/forensics dial, NOT a
  # claimed SOC 2 control: the LB 5xx/503 alerts read the platform request_count
  # metric, not this log, so 0 (off) breaks no alert and no compliance claim.
  log_config {
    enable      = var.lb_request_log_sampling > 0
    sample_rate = var.lb_request_log_sampling
  }

  backend {
    group           = google_compute_region_instance_group_manager.emisar.instance_group
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }

  lifecycle {
    create_before_destroy = true
  }
}

ephemeral "google_client_config" "current" {}

# Creating a backend service does not mean its health-check state has propagated.
# Switching the URL map earlier produced a full 503 outage even though both VMs
# were ready. Fail closed on the old serving path until Compute reports every
# expected instance healthy through the successor backend service.
resource "terraform_data" "app_backend_ready" {
  triggers_replace = [google_compute_backend_service.app.id]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail

      for tool in curl grep mktemp seq sleep tr wc; do
        command -v "$tool" >/dev/null || {
          echo "backend readiness check requires $tool" >&2
          exit 1
        }
      done

      url="https://compute.googleapis.com/compute/v1/projects/$PROJECT_ID/global/backendServices/$BACKEND_SERVICE/getHealth"
      payload=$(printf '{"group":"%s"}' "$INSTANCE_GROUP")
      response_file=$(mktemp)
      trap 'rm -f "$response_file"' EXIT

      for attempt in $(seq 1 60); do
        if ! status=$(curl --silent --show-error \
          --connect-timeout 5 --max-time 30 --output "$response_file" \
          --write-out '%%{http_code}' \
          -X POST \
          -H "Authorization: Bearer $ACCESS_TOKEN" \
          -H "Content-Type: application/json" \
          --data "$payload" \
          "$url"); then
          echo "backend health request failed on attempt $attempt" >&2
          exit 1
        fi

        case "$status" in
          200) ;;
          429|5??)
            sleep 10
            continue
            ;;
          401|403)
            echo "backend health authentication was rejected with HTTP $status" >&2
            exit 1
            ;;
          *)
            echo "backend health request returned unexpected HTTP $status" >&2
            exit 1
            ;;
        esac

        healthy=$(tr -d '[:space:]' < "$response_file" | \
          grep -o '"healthState":"HEALTHY"' | wc -l | tr -d ' ') || healthy=0

        if [ "$healthy" -ge "$EXPECTED_INSTANCES" ]; then
          exit 0
        fi

        sleep 10
      done

      echo "backend $BACKEND_SERVICE did not reach $EXPECTED_INSTANCES healthy instances" >&2
      exit 1
    EOT

    environment = {
      ACCESS_TOKEN       = ephemeral.google_client_config.current.access_token
      BACKEND_SERVICE    = google_compute_backend_service.app.name
      EXPECTED_INSTANCES = tostring(var.database_owner_role_ready ? var.instance_count : 0)
      INSTANCE_GROUP     = google_compute_region_instance_group_manager.emisar.instance_group
      PROJECT_ID         = var.project_id
    }
  }
}

# ── TLS policy: modern ciphers, TLS 1.2+ ─────────────────────────────────────
resource "google_compute_ssl_policy" "restricted" {
  name            = "emisar-ssl"
  profile         = "RESTRICTED"
  min_tls_version = "TLS_1_2"
}

# ── HTTPS front end ──────────────────────────────────────────────────────────
resource "google_compute_url_map" "https" {
  name            = "emisar-https"
  default_service = google_compute_backend_service.app.id

  depends_on = [
    terraform_data.app_backend_ready,
    terraform_data.livebook_backend_ready,
  ]

  # registry.<domain> serves the public pack-registry bucket straight from the
  # LB (pack_registry.tf) — no portal hop, so `emisar pack install` keeps
  # working even when the app tier is down or mid-deploy.
  host_rule {
    hosts        = ["registry.${var.domain}"]
    path_matcher = "pack-registry"
  }

  host_rule {
    hosts        = ["www.${var.domain}"]
    path_matcher = "www-to-apex"
  }

  host_rule {
    hosts        = ["mta-sts.${var.domain}"]
    path_matcher = "mta-sts"
  }

  dynamic "host_rule" {
    for_each = google_compute_backend_service.livebook
    content {
      hosts        = ["livebook.${var.domain}"]
      path_matcher = "livebook"
    }
  }

  path_matcher {
    name            = "pack-registry"
    default_service = google_compute_backend_bucket.pack_registry.id
  }

  path_matcher {
    name = "www-to-apex"
    default_url_redirect {
      host_redirect          = var.domain
      redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
      strip_query            = false
    }
  }

  path_matcher {
    name            = "mta-sts"
    default_service = google_compute_backend_bucket.mta_sts.id
  }

  dynamic "path_matcher" {
    for_each = google_compute_backend_service.livebook
    content {
      name            = "livebook"
      default_service = path_matcher.value.id

      path_rule {
        paths   = ["/public/*"]
        service = google_compute_backend_service.livebook_public[0].id
      }
    }
  }

  dynamic "test" {
    for_each = google_compute_backend_service.livebook_public
    content {
      description = "Livebook public widget assets bypass IAP"
      host        = "livebook.${var.domain}"
      path        = "/public/sessions/example/assets/example/main.js"
      service     = test.value.id
    }
  }

  dynamic "test" {
    for_each = google_compute_backend_service.livebook
    content {
      description = "Livebook operator routes remain behind IAP"
      host        = "livebook.${var.domain}"
      path        = "/sessions/example"
      service     = test.value.id
    }
  }
}

# URL-map updates can reach the control plane before every edge proxy. Keep the
# previous backend alive for five minutes after the switch; otherwise lagging
# edges can return 503 while still resolving the previous backend reference.
resource "terraform_data" "app_backend_edge_propagated" {
  # All three graph edges are load-bearing: this trigger ties the old hold to
  # the old backend, depends_on puts its successor after the URL-map update, and
  # create_before_destroy keeps the old hold until the successor sleep finishes.
  triggers_replace = [google_compute_backend_service.app.id]

  depends_on = [google_compute_url_map.https]

  provisioner "local-exec" {
    command = "sleep 300"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_compute_target_https_proxy" "https" {
  name            = "emisar-https-proxy"
  url_map         = google_compute_url_map.https.id
  certificate_map = "//certificatemanager.googleapis.com/${google_certificate_manager_certificate_map.emisar.id}"
  ssl_policy      = google_compute_ssl_policy.restricted.id
}

resource "google_compute_global_forwarding_rule" "https_v4" {
  name                  = "emisar-https-v4"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_address            = google_compute_global_address.ipv4.id
  port_range            = "443"
  target                = google_compute_target_https_proxy.https.id
}

resource "google_compute_global_forwarding_rule" "https_v6" {
  name                  = "emisar-https-v6"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_address            = google_compute_global_address.ipv6.id
  port_range            = "443"
  target                = google_compute_target_https_proxy.https.id
}

# ── HTTP → HTTPS redirect front end ──────────────────────────────────────────
resource "google_compute_url_map" "redirect" {
  name = "emisar-http-redirect"
  default_url_redirect {
    https_redirect         = true
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    strip_query            = false
  }


  host_rule {
    hosts        = ["www.${var.domain}"]
    path_matcher = "www-to-apex"
  }

  path_matcher {
    name = "www-to-apex"
    default_url_redirect {
      host_redirect          = var.domain
      https_redirect         = true
      redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
      strip_query            = false
    }
  }
}

resource "google_compute_target_http_proxy" "redirect" {
  name    = "emisar-http-proxy"
  url_map = google_compute_url_map.redirect.id
}

resource "google_compute_global_forwarding_rule" "http_v4" {
  name                  = "emisar-http-v4"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_address            = google_compute_global_address.ipv4.id
  port_range            = "80"
  target                = google_compute_target_http_proxy.redirect.id
}

resource "google_compute_global_forwarding_rule" "http_v6" {
  name                  = "emisar-http-v6"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_address            = google_compute_global_address.ipv6.id
  port_range            = "80"
  target                = google_compute_target_http_proxy.redirect.id
}
