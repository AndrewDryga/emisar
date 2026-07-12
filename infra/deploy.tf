# ── Keyless GitHub Actions → GCP federation (packs publishing only) ───────────
# GitHub's OIDC token exchanges at this pool, so no service-account key exists
# anywhere (AGENTS.md §2). Its ONE consumer is the pack-publish job in the
# main-only CD workflow, which impersonates the pack-registry publisher
# (packs_registry.tf) to upload artifacts.
#
# Deliberately NOT used for app deploys: a deploy IS a Terraform run — the
# CD uploads the exact infra configuration CI tested and queues an HCP
# Terraform run. A human confirms that exact saved plan in HCP Terraform, so
# state records exactly what runs and no imperative gcloud deploy identity or
# automated apply credential exists in GitHub Actions.
#
# Trust is pinned twice: the provider admits only the publication environment
# job in the main workflow on main (the preceding pack-registry job carries
# human approval), and the publisher SA binding independently requires that
# exact environment principal.

resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github-actions"
  display_name              = "GitHub Actions"
  description               = "OIDC federation for the repo's CI/CD workflows"
  depends_on                = [google_project_service.apis]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  display_name                       = "GitHub OIDC"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }

  attribute_mapping = {
    "google.subject"         = "assertion.sub"
    "attribute.repository"   = "assertion.repository"
    "attribute.ref"          = "assertion.ref"
    "attribute.workflow_ref" = "assertion.workflow_ref"
    "attribute.environment"  = "assertion.environment"
  }

  attribute_condition = join(" && ", [
    "assertion.repository == \"${var.github_repository}\"",
    "assertion.ref == \"refs/heads/main\"",
    "assertion.workflow_ref == \"${var.github_repository}/.github/workflows/cd.yml@refs/heads/main\"",
    "assertion.environment == \"pack-registry-production\"",
  ])
}
