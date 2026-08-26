# Keyless GitHub Actions federation is used only by the pack and release
# publishers. Portal delivery remains a reviewed HCP Terraform plan from this
# single workspace. Pack CD and component releases use separate providers
# because only reusable-workflow jobs carry `job_workflow_*` claims.
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
  # environment names can all be reproduced after a rename or transfer. This
  # provider admits only the protected-main pack publisher. Component releases
  # use the reusable-workflow-bound provider below.
  attribute_condition = join(" && ", [
    "assertion.repository == \"${var.github_repository}\"",
    "assertion.repository_id == \"${var.github_repository_id}\"",
    "assertion.ref == \"refs/heads/main\"",
    "assertion.workflow_ref == \"${var.github_repository}/.github/workflows/cd.yml@refs/heads/main\"",
    "assertion.environment == \"pack-registry-production\"",
  ])
}

# Release jobs run only from these no-input reusable workflows at the exact
# reviewed commit. The tag-selected callers still describe the source ref, but
# neither their mutable workflow_ref nor a matching tag name grants cloud
# authority. Rotation lands new called workflows first, then changes both exact
# values here and in the callers in one later plan.
resource "google_iam_workload_identity_pool_provider" "github_releases" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-releases"
  display_name                       = "Emisar: GitHub Releases"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }

  attribute_mapping = {
    "google.subject"             = "assertion.sub"
    "attribute.repository"       = "assertion.repository"
    "attribute.repository_id"    = "assertion.repository_id"
    "attribute.ref"              = "assertion.ref"
    "attribute.environment"      = "assertion.environment"
    "attribute.job_workflow_ref" = "assertion.job_workflow_ref"
    "attribute.job_workflow_sha" = "assertion.job_workflow_sha"
  }

  attribute_condition = join(" && ", [
    "assertion.repository == \"${var.github_repository}\"",
    "assertion.repository_id == \"${var.github_repository_id}\"",
    "assertion.environment == \"public-releases\"",
    "assertion.job_workflow_sha == \"e20ae8f8e98931868b369b7c1d58892a28ad219d\"",
    "(${join(" || ", [
      "(assertion.ref.startsWith(\"refs/tags/runner-v\") && assertion.job_workflow_ref == \"${var.github_repository}/.github/workflows/runner-release-trusted.yml@e20ae8f8e98931868b369b7c1d58892a28ad219d\")",
      "(assertion.ref.startsWith(\"refs/tags/mcp-v\") && assertion.job_workflow_ref == \"${var.github_repository}/.github/workflows/mcp-release-trusted.yml@e20ae8f8e98931868b369b7c1d58892a28ad219d\")",
    ])})",
  ])
}
