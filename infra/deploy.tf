# ── Keyless GitHub Actions → GCP federation (packs publishing only) ───────────
# GitHub's OIDC token exchanges at this pool, so no service-account key exists
# anywhere (AGENTS.md §2). Its ONE consumer is the "CD · Packs" workflow, which
# impersonates the pack-registry publisher (packs_registry.tf) to upload
# artifacts.
#
# Deliberately NOT used for app deploys: a deploy IS a Terraform run — the
# "CD · Portal" workflow sets container_image to the freshly pushed image in
# the TFC workspace and queues an apply, so the template replace rolls the
# fleet, state records exactly what runs, and no imperative gcloud (or GCP
# deploy identity) exists in CI at all.
#
# Trust is pinned twice: the provider's attribute_condition only admits tokens
# minted for THIS repository, and the publisher SA's workloadIdentityUser
# binding only trusts that same repository's principalSet. The human gate
# stays in GitHub — the consuming jobs are `release`-environment-gated
# (required reviewers).

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
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  # Only tokens minted for this repository exchange — a fork or any other repo
  # on GitHub's shared OIDC issuer gets nothing.
  attribute_condition = "assertion.repository == \"${var.github_repository}\""
}
