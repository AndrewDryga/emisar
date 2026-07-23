# `google-monitoring-enabled` enables COS Node Problem Detector, whose guest
# metrics are reported against each VM. The portal-only instance label keeps
# these policies scoped to the MIG and excludes the optional Livebook VM.
resource "google_monitoring_alert_policy" "portal_cpu" {
  display_name = "Emisar: Portal VM CPU High"
  combiner     = "OR"

  documentation {
    content   = "Portal VM CPU utilization has remained above 85% for five minutes. Inspect the affected instance, application load, and most recent rollout before changing capacity."
    mime_type = "text/markdown"
  }

  user_labels = {
    component = "portal-vm"
    signal    = "cpu"
  }

  conditions {
    display_name = "Portal VM CPU Above 85% for 5 Minutes"
    condition_threshold {
      filter          = "resource.type = \"gce_instance\" AND metadata.user_labels.cluster_name = \"emisar\" AND metric.type = \"compute.googleapis.com/instance/cpu/utilization\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0.85
      duration        = "300s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = local.alert_notification_channels
}

resource "google_monitoring_alert_policy" "portal_memory" {
  display_name = "Emisar: Portal VM Memory High"
  combiner     = "OR"

  documentation {
    content   = "Portal VM memory utilization has remained above 90% for five minutes. Inspect the affected instance and application memory usage for a leak or undersized workload."
    mime_type = "text/markdown"
  }

  user_labels = {
    component = "portal-vm"
    signal    = "memory"
  }

  conditions {
    display_name = "Portal VM Memory Above 90% for 5 Minutes"
    condition_threshold {
      filter          = "resource.type = \"gce_instance\" AND metadata.user_labels.cluster_name = \"emisar\" AND metric.type = \"compute.googleapis.com/guest/memory/percent_used\" AND metric.labels.state = \"used\""
      comparison      = "COMPARISON_GT"
      threshold_value = 90
      duration        = "300s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = local.alert_notification_channels
}

resource "google_monitoring_alert_policy" "portal_disk" {
  display_name = "Emisar: Portal VM Disk Near Full"
  combiner     = "OR"

  documentation {
    content   = "Portal VM disk utilization has remained above 90% for five minutes. Inspect the affected device and release or container logs for unexpected disk growth before the VM reaches capacity."
    mime_type = "text/markdown"
  }

  user_labels = {
    component = "portal-vm"
    signal    = "disk"
  }

  conditions {
    display_name = "Portal VM Disk Above 90% for 5 Minutes"
    condition_threshold {
      filter          = "resource.type = \"gce_instance\" AND metadata.user_labels.cluster_name = \"emisar\" AND metric.type = \"compute.googleapis.com/guest/disk/percent_used\""
      comparison      = "COMPARISON_GT"
      threshold_value = 90
      duration        = "300s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = local.alert_notification_channels
}

# Users seeing errors while the readiness check still passes — a sustained 5xx
# ratio at the LB is the signal
# that real traffic is failing. Ratio, not count, so it doesn't scale with
# traffic volume.
resource "google_monitoring_alert_policy" "lb_5xx" {
  display_name = "Emisar: Load Balancer 5xx Ratio High"
  combiner     = "OR"

  conditions {
    display_name = "5xx Responses Above 5% for 5 Minutes"
    condition_threshold {
      filter             = "resource.type = \"https_lb_rule\" AND metric.type = \"loadbalancing.googleapis.com/https/request_count\" AND metric.labels.response_code_class = 500"
      denominator_filter = "resource.type = \"https_lb_rule\" AND metric.type = \"loadbalancing.googleapis.com/https/request_count\""
      comparison         = "COMPARISON_GT"
      threshold_value    = 0.05
      duration           = "300s"
      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_RATE"
        cross_series_reducer = "REDUCE_SUM"
      }
      denominator_aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_RATE"
        cross_series_reducer = "REDUCE_SUM"
      }
    }
  }

  notification_channels = local.alert_notification_channels
}

resource "google_monitoring_alert_policy" "lb_no_healthy_backends" {
  display_name = "Emisar: Load Balancer Zero Healthy Backends"
  combiner     = "OR"

  documentation {
    content   = "The portal backend is returning HTTP 503 responses through the global external Application Load Balancer for five minutes. Google documents 503 as the response when all backends are unhealthy; this is the closest native metric signal because Cloud Monitoring does not expose a clean healthy-backend-count metric for this load balancer. Confirm the incident with load-balancer logs and statusDetails=failed_to_pick_backend, since a backend-generated 503 can produce the same metric."
    mime_type = "text/markdown"
  }

  user_labels = {
    component = "load-balancer"
    signal    = "backend-health"
  }

  conditions {
    display_name = "Portal Backend HTTP 503 for 5 Minutes"
    condition_threshold {
      filter          = "resource.type = \"https_lb_rule\" AND resource.labels.backend_target_name = \"${google_compute_backend_service.app.name}\" AND metric.type = \"loadbalancing.googleapis.com/https/request_count\" AND metric.labels.response_code = 503"
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "300s"
      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_RATE"
        cross_series_reducer = "REDUCE_SUM"
      }
    }
  }

  notification_channels = local.paging_notification_channels
}

# The managed certs auto-renew, so a shrinking expiry window means renewal is
# FAILING (DNS auth broken, CAA blocking issuance) — two weeks is enough
# runway to fix it before browsers hard-fail. Measured by the uptime check
# (validate_ssl above), so it watches the cert actually served, not the one
# Certificate Manager thinks it provisioned.
resource "google_monitoring_alert_policy" "cert_expiry" {
  display_name = "Emisar: TLS Certificate Expiring"
  combiner     = "OR"

  conditions {
    display_name = "Served Certificate Expires Within 14 Days"
    condition_threshold {
      filter          = "resource.type = \"uptime_url\" AND metric.type = \"monitoring.googleapis.com/uptime_check/time_until_ssl_cert_expires\" AND metric.label.check_id = \"${google_monitoring_uptime_check_config.https.uptime_check_id}\""
      comparison      = "COMPARISON_LT"
      threshold_value = 14
      duration        = "600s"
      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_MIN"
        cross_series_reducer = "REDUCE_MIN"
        group_by_fields      = ["resource.label.host"]
      }
    }
  }

  notification_channels = local.alert_notification_channels
}

# The zero-unavailable rollout should never put the MIG below target. Remaining
# below target for 15m means repair or creation is genuinely stuck.
resource "google_monitoring_alert_policy" "mig_below_target" {
  display_name = "Emisar: Instance Group Below Target"
  combiner     = "OR"

  conditions {
    display_name = "Running Instances Below Target for 15 Minutes"
    condition_threshold {
      filter          = "resource.type = \"instance_group\" AND resource.labels.instance_group_name = \"${google_compute_region_instance_group_manager.emisar.name}\" AND metric.type = \"compute.googleapis.com/instance_group/size\""
      comparison      = "COMPARISON_LT"
      threshold_value = var.instance_count
      duration        = "900s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = local.paging_notification_channels
}

# NAT port exhaustion silently breaks all egress (GHCR pulls on boot, Postmark,
# Paddle, Sentry) while ingress keeps working — nothing else surfaces it until
# a rollout can't pull the image or emails stop sending.
resource "google_monitoring_alert_policy" "nat_allocation" {
  display_name = "Emisar: Cloud NAT Allocation Failure"
  combiner     = "OR"

  conditions {
    display_name = "NAT Port Allocation Failures"
    condition_threshold {
      filter          = "resource.type = \"nat_gateway\" AND metric.type = \"router.googleapis.com/nat/nat_allocation_failed\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "300s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_COUNT_TRUE"
      }
    }
  }

  notification_channels = local.paging_notification_channels
}

