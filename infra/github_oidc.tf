# Keyless GitHub Actions federation is used only by the pack publisher. Portal
# delivery remains a reviewed HCP Terraform plan from this single workspace.
resource "google_iam_workload_identity_pool" "github" {
  project                   = var.project_id
  workload_identity_pool_id = "github-actions"
  display_name              = "Emisar: GitHub Actions"
  description               = "OIDC federation for the repository's production pack publisher"
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

  # Every claim below is a NAME, and GitHub does not reserve a repository path
  # after a rename or transfer — so whoever claims the old path could satisfy
  # all of them from their own workflow and mint a token that publishes packs
  # customer runners execute. repository_id is immutable; pin it too when known.
  attribute_condition = join(" && ", concat([
    "assertion.repository == \"${var.github_repository}\"",
    "assertion.ref == \"refs/heads/main\"",
    "assertion.workflow_ref == \"${var.github_repository}/.github/workflows/cd.yml@refs/heads/main\"",
    "assertion.environment == \"pack-registry-production\"",
    ], var.github_repository_id == "" ? [] : [
    "assertion.repository_id == \"${var.github_repository_id}\"",
  ]))
}
