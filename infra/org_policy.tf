locals {
  managed_boolean_guardrails = toset([
    "compute.managed.vmCanIpForward",
    "compute.managed.vmExternalIpAccess",
    "iam.managed.disableServiceAccountKeyCreation",
    "iam.managed.disableServiceAccountKeyUpload",
    "iam.managed.preventPrivilegedBasicRolesForDefaultServiceAccounts",
    "sql.managed.restrictAuthorizedNetworks",
    "sql.managed.restrictPublicIp",
  ])

  classic_boolean_guardrails = toset([
    "compute.requireShieldedVm",
    "storage.uniformBucketLevelAccess",
  ])
}

# Land managed constraints in dry-run first. Promotion is an explicit reviewed
# change after Policy Simulator confirms production resources remain compliant.
resource "google_org_policy_policy" "guardrail" {
  for_each        = local.managed_boolean_guardrails
  name            = "projects/${data.google_project.current.number}/policies/${each.value}"
  parent          = "projects/${data.google_project.current.number}"
  deletion_policy = "PREVENT"

  dry_run_spec {
    rules {
      enforce = "TRUE"
    }
  }

  dynamic "spec" {
    for_each = var.enforce_org_policies ? [1] : []
    content {
      rules {
        enforce = "TRUE"
      }
    }
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.apis]
}

# Classic constraints lack dry-run support, so keep an explicit disabled spec
# until the same reviewed promotion.
resource "google_org_policy_policy" "classic_guardrail" {
  for_each        = local.classic_boolean_guardrails
  name            = "projects/${data.google_project.current.number}/policies/${each.value}"
  parent          = "projects/${data.google_project.current.number}"
  deletion_policy = "PREVENT"

  spec {
    rules {
      enforce = var.enforce_org_policies ? "TRUE" : "FALSE"
    }
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.apis]
}
