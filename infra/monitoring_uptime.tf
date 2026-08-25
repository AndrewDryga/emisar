# External readiness check proves the site and its database are serving.
resource "google_monitoring_uptime_check_config" "https" {
  display_name = "Emisar: Control Plane Readiness"
  timeout      = "10s"
  period       = "60s"

  http_check {
    path         = "/readyz"
    port         = 443
    use_ssl      = true
    validate_ssl = true
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project_id
      host       = var.domain
    }
  }

  depends_on = [google_project_service.apis]
}

resource "google_monitoring_uptime_check_config" "pack_registry_semantic" {
  display_name = "Emisar: Pack Registry Catalog Semantics"
  timeout      = "10s"
  period       = "300s"

  http_check {
    path         = "/v1/catalog.json"
    port         = 443
    use_ssl      = true
    validate_ssl = true
  }

  # Regex containment, not JSONPath: uptime checks inspect only the first
  # 1 MB of a response, and the catalog is larger — a JSONPath matcher needs
  # the complete document to parse, while the schema_version field sits in
  # the first bytes. The \s* tolerates both the compact form packctl now
  # publishes and the pretty-printed catalog still live until the next
  # pack release.
  content_matchers {
    content = "\"schema_version\":\\s*1"
    matcher = "MATCHES_REGEX"
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project_id
      host       = "registry.${var.domain}"
    }
  }

  depends_on = [google_project_service.apis]
}

resource "google_monitoring_alert_policy" "uptime" {
  display_name = "Emisar: Control Plane Unreachable"
  combiner     = "OR"

  documentation {
    content   = "The external HTTPS readiness check has failed for five minutes, so the control plane or its database is not serving successfully from at least one checker. Confirm the public endpoint and `/readyz`, then inspect DNS and TLS, load-balancer backend health, Portal errors, Cloud SQL availability, and the most recent rollout to locate the failing layer."
    mime_type = "text/markdown"
  }

  user_labels = {
    component = "control-plane"
    signal    = "availability"
  }

  conditions {
    display_name = "Uptime Check Failed"
    condition_threshold {
      filter          = "resource.type = \"uptime_url\" AND metric.type = \"monitoring.googleapis.com/uptime_check/check_passed\" AND metric.label.check_id = \"${google_monitoring_uptime_check_config.https.uptime_check_id}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 1
      duration        = "300s"

      aggregations {
        alignment_period     = "1200s"
        per_series_aligner   = "ALIGN_NEXT_OLDER"
        cross_series_reducer = "REDUCE_COUNT_FALSE"
        group_by_fields      = ["resource.label.host"]
      }
      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.alert_notification_channels
}

resource "google_monitoring_alert_policy" "pack_registry_checks" {
  display_name = "Emisar: Pack Registry Integrity Check Failed"
  combiner     = "OR"

  documentation {
    content   = "The public pack catalog no longer returns the expected schema marker for ten minutes, so clients may be unable to read a valid registry even if the endpoint still returns HTTP success. Fetch the catalog directly, confirm its status and leading response body, then check the latest pack publication, registry hosting, and cache behavior before republishing."
    mime_type = "text/markdown"
  }

  user_labels = {
    component = "pack-registry"
    signal    = "integrity"
  }

  dynamic "conditions" {
    for_each = {
      semantic = google_monitoring_uptime_check_config.pack_registry_semantic.uptime_check_id
    }
    content {
      display_name = "${title(conditions.key)} check failed"
      condition_threshold {
        filter          = "resource.type = \"uptime_url\" AND metric.type = \"monitoring.googleapis.com/uptime_check/check_passed\" AND metric.label.check_id = \"${conditions.value}\""
        comparison      = "COMPARISON_GT"
        threshold_value = 1
        duration        = "600s"

        aggregations {
          alignment_period     = "1200s"
          per_series_aligner   = "ALIGN_NEXT_OLDER"
          cross_series_reducer = "REDUCE_COUNT_FALSE"
          group_by_fields      = ["resource.label.host"]
        }
        trigger {
          count = 1
        }
      }
    }
  }

  notification_channels = local.alert_notification_channels
}
