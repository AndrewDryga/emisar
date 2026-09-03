# The bucket IAM bindings are the preventive control: one publisher writes pack
# objects and one writes binary releases. Retain every DATA_WRITE entry in the
# locked evidence bucket, then page when the audit identity is neither of those
# exact service accounts. This also detects an unexpected writer under the two
# facade aliases and releases/** instead of relying on an object-path field that
# differs across Storage APIs.
#
# A stolen expected-publisher token is deliberately not detectable by identity
# alone, and neither expected identity pages when it attempts the other one's
# namespace. Those operations remain in the evidence bucket for investigation;
# WIF claim restrictions, environment approval, exact object-path IAM, and
# create-only immutable prefixes are the preventive controls for those cases.
locals {
  expected_pack_registry_writers = [
    google_service_account.pack_publisher.email,
    google_service_account.release_publisher.email,
  ]
}

resource "google_logging_metric" "unexpected_pack_registry_write" {
  project = var.project_id
  name    = "emisar_unexpected_pack_registry_write"

  filter = join(" AND ", concat(
    [local.pack_registry_data_write_filter],
    [
      for email in local.expected_pack_registry_writers :
      "NOT protoPayload.authenticationInfo.principalEmail=\"${email}\""
    ],
  ))

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
  }

  depends_on = [google_project_service.apis]
}

resource "google_monitoring_alert_policy" "unexpected_pack_registry_write" {
  display_name = "Emisar: Unexpected Action Pack Registry Write"
  combiner     = "OR"

  documentation {
    content   = "A principal other than the pack or release publisher attempted a Data Write operation against the public Action Pack Registry bucket. Treat this as a supply-chain incident until shown otherwise: identify the principal and operation in the security-evidence bucket, inspect the audit status to determine whether the attempt succeeded, revoke unexpected access, and compare the affected object generation and bytes with the trusted build before repairing any live pointer. The expected publisher identities are excluded, so a stolen publisher token remains a forensic-evidence case rather than an identity anomaly."
    mime_type = "text/markdown"
  }

  user_labels = {
    component = "pack-registry"
    signal    = "security"
  }

  conditions {
    display_name = "Registry Data Write By An Unexpected Principal"
    condition_threshold {
      filter          = "resource.type = \"gcs_bucket\" AND metric.type = \"logging.googleapis.com/user/${google_logging_metric.unexpected_pack_registry_write.name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_DELTA"
      }
    }
  }

  notification_channels = local.paging_notification_channels
}
