# Keyless GitHub Actions federation is used only by the pack and release
# publishers. Portal delivery remains a reviewed HCP Terraform plan from this
# single workspace.
resource "google_iam_workload_identity_pool" "github" {
  project                   = var.project_id
  workload_identity_pool_id = "github-actions"
  display_name              = "Emisar: GitHub Actions"
  description               = "OIDC federation for the repository's production artifact publishers"
  depends_on                = [google_project_service.apis]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  display_name                       = "Emisar: GitHub OIDC"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }

  attribute_mapping = {
    "google.subject"          = "assertion.sub"
    "attribute.repository"    = "assertion.repository"
    "attribute.repository_id" = "assertion.repository_id"
    "attribute.ref"           = "assertion.ref"
    "attribute.workflow_ref"  = "assertion.workflow_ref"
    "attribute.environment"   = "assertion.environment"
  }

  # repository_id is the immutable anchor; repository, workflow, ref, and
  # environment names can all be reproduced after a rename or transfer. Each
  # alternative below pins one exact publisher workflow and its admitted refs.
  attribute_condition = join(" && ", [
    "assertion.repository == \"${var.github_repository}\"",
    "assertion.repository_id == \"${var.github_repository_id}\"",
    "(${join(" || ", [
      "(assertion.ref == \"refs/heads/main\" && assertion.workflow_ref == \"${var.github_repository}/.github/workflows/cd.yml@refs/heads/main\" && assertion.environment == \"pack-registry-production\")",
      "(assertion.ref.startsWith(\"refs/tags/runner-v\") && assertion.workflow_ref.startsWith(\"${var.github_repository}/.github/workflows/runner-release.yml@refs/tags/runner-v\") && assertion.environment == \"public-releases\")",
      "(assertion.ref.startsWith(\"refs/tags/mcp-v\") && assertion.workflow_ref.startsWith(\"${var.github_repository}/.github/workflows/mcp-release.yml@refs/tags/mcp-v\") && assertion.environment == \"public-releases\")",
    ])})",
  ])
}
