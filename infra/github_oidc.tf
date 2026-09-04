# Keyless GitHub Actions federation is used only by the pack and release
# publishers. Portal delivery remains a reviewed HCP Terraform plan from this
# single workspace. Pack CD and component releases use separate providers
# because only reusable-workflow jobs carry `job_workflow_*` claims.
locals {
  # The reviewed commit the release workflows must run from. It is asserted here
  # AND used to build the pack-registry publisher's principalSet in
  # pack_registry.tf, so a rotation that updates only some of the four spellings
  # does not fail a plan — it silently stops matching, and the publisher loses
  # authority (or, worse, an unreviewed commit keeps it). One definition makes
  # the rotation a single edit. See the rotation note on
  # google_iam_workload_identity_pool_provider.github_releases below.
  trusted_job_workflow_sha = "1a2a47c132d148cf4e837634650839d582003d1e"

  # Workflow identities carry the repository path, so during the transfer
  # window every path in var.github_repositories yields one accepted spelling.
  # jsonencode renders a valid CEL list literal for the `in` conditions below.
  cd_workflow_refs = [
    for repository in var.github_repositories :
    "${repository}/.github/workflows/cd.yml@refs/heads/main"
  ]
  runner_release_workflow_refs = [
    for repository in var.github_repositories :
    "${repository}/.github/workflows/runner-release-trusted.yml@${local.trusted_job_workflow_sha}"
  ]
  mcp_release_workflow_refs = [
    for repository in var.github_repositories :
    "${repository}/.github/workflows/mcp-release-trusted.yml@${local.trusted_job_workflow_sha}"
  ]
}

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
    "assertion.repository in ${jsonencode(var.github_repositories)}",
    "assertion.repository_id == \"${var.github_repository_id}\"",
    "assertion.ref == \"refs/heads/main\"",
    "assertion.workflow_ref in ${jsonencode(local.cd_workflow_refs)}",
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
    "assertion.repository in ${jsonencode(var.github_repositories)}",
    "assertion.repository_id == \"${var.github_repository_id}\"",
    "assertion.environment == \"public-releases\"",
    "assertion.job_workflow_sha == \"${local.trusted_job_workflow_sha}\"",
    "(${join(" || ", [
      "(assertion.ref.startsWith(\"refs/tags/runner-v\") && assertion.job_workflow_ref in ${jsonencode(local.runner_release_workflow_refs)})",
      "(assertion.ref.startsWith(\"refs/tags/mcp-v\") && assertion.job_workflow_ref in ${jsonencode(local.mcp_release_workflow_refs)})",
    ])})",
  ])
}
