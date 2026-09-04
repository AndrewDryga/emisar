# Secret Manager access by a principal we did not expect.
#
# `google_logging_project_sink.security_evidence` collects every
# AccessSecretVersion into a 400-day locked bucket, and nothing read it. This
# turns that evidence into detection for ONE case: a principal outside the
# expected set below — a leaked user credential, a new service account, a
# foreign identity — reading a secret version.
#
# Be precise about what it does NOT catch, because the exclusion list is load
# bearing and reads like an oversight. An attacker holding the VM service
# account's token is EXEMPT here by design: that identity reads all eleven
# secrets on every boot, so alerting on it would page on each instance
# replacement and be muted within a week. Stolen-VM-token abuse stays an
# evidence-sink question, answered from the locked bucket after the fact, not a
# page. Do not "fix" this by dropping the VM SA from expected_secret_readers —
# that trades a real control for a noisy one. If we want that case to page, it
# needs a RATE condition over the boot-time baseline (instance_count ×
# len(runtime_secrets) per hour), which is a separate policy.

locals {
  # The principals whose access is routine. Splat, not [0] — Livebook is
  # count-gated, and a hard index would make disabling it a graph edit rather
  # than a flag flip.
  expected_secret_readers = concat(
    [google_service_account.vm.email],
    google_service_account.livebook[*].email,
    # The apply identity is excluded deliberately. The provider reads secret
    # versions during refresh, so including it would fire on every plan — and an
    # alert that pages on ordinary work is one people learn to close. Its access
    # is bounded by Terraform Cloud custody, which is production access reviewed
    # on its own terms (see infra/AGENTS.md rule 4).
    ["terraform@${var.project_id}.iam.gserviceaccount.com"],
  )

  # HCP runs plans as a SECOND identity (.github/DEPLOYMENT.md): read-only
  # review roles, deliberately without secretmanager.versions.access. The
  # exclusion above was written when there was one Terraform identity, so a
  # refresh that touches a secret version is audited as a PERMISSION_DENIED by a
  # principal this metric does not know — and pages "Treat as a credential
  # incident" for the read-only identity doing exactly what it is scoped to be
  # refused. Only its DENIAL is excluded, not the principal: if the plan
  # identity ever SUCCEEDS at reading a secret, the read-only boundary has
  # broken and that is precisely what this alert should say.
  expected_secret_denial = join(" AND ", [
    "protoPayload.authenticationInfo.principalEmail=\"terraform-plan@${var.project_id}.iam.gserviceaccount.com\"",
    "protoPayload.status.code=7", # gRPC PERMISSION_DENIED
  ])
}

resource "google_logging_metric" "unexpected_secret_access" {
  project = var.project_id
  name    = "emisar_unexpected_secret_access"

  filter = join(" AND ", concat(
    [
      "protoPayload.serviceName=\"secretmanager.googleapis.com\"",
      "protoPayload.methodName=\"google.cloud.secretmanager.v1.SecretManagerService.AccessSecretVersion\"",
    ],
    [
      for email in local.expected_secret_readers :
      "NOT protoPayload.authenticationInfo.principalEmail=\"${email}\""
    ],
    ["NOT (${local.expected_secret_denial})"],
  ))

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
  }

  depends_on = [google_project_service.apis]
}

resource "google_monitoring_alert_policy" "unexpected_secret_access" {
  display_name = "Emisar: Unexpected Secret Manager Access"
  combiner     = "OR"

  documentation {
    content   = "A principal that is neither the portal VM, the Livebook workbench, nor the Terraform apply identity read a secret version. Treat as a credential incident until shown otherwise: identify the principal in the security-evidence bucket, establish how it obtained the token, then rotate every secret it could reach. Reading a secret is not reversible — assume disclosure."
    mime_type = "text/markdown"
  }

  user_labels = {
    component = "secret-manager"
    signal    = "security"
  }

  conditions {
    display_name = "Secret Read By An Unexpected Principal"
    condition_threshold {
      # Monitoring rejects a condition filter that does not restrict resource.type.
      # Secret Manager has no monitored resource of its own, so its audit entries —
      # and therefore this metric's series — carry the generic `audited_resource`.
      filter          = "resource.type = \"audited_resource\" AND metric.type = \"logging.googleapis.com/user/${google_logging_metric.unexpected_secret_access.name}\""
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
