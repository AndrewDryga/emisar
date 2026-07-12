# ── One-click CD: keyless GitHub Actions → GCP deploy identity ────────────────
# The "CD · portal" workflow (.github/workflows/portal-cd.yml) publishes the
# image to public GHCR, then rolls the MIG so instances re-pull it. The roll
# needs GCP credentials; like the Terraform Cloud apply identity, it gets them
# via Workload Identity Federation — GitHub's OIDC token is exchanged at this
# pool, so no service-account key exists anywhere (AGENTS.md §2).
#
# Trust is pinned twice: the provider's attribute_condition only admits tokens
# minted for THIS repository, and the deployer SA's workloadIdentityUser
# binding only trusts that same repository's principalSet. The human gate
# stays in GitHub — the workflow's publish job is `release`-environment-gated
# (required reviewers), and the deploy job can't run without it.

resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github-actions"
  display_name              = "GitHub Actions"
  description               = "OIDC federation for the repo's CD workflow"
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

# The deploy identity carries exactly what a MIG rolling replace needs — a
# custom role, not roles/compute.instanceAdmin.v1, which could rewrite any
# instance in the project.
resource "google_service_account" "deployer" {
  account_id   = "emisar-deployer"
  display_name = "emisar GitHub Actions deployer"
}

resource "google_project_iam_custom_role" "deployer" {
  role_id     = "emisarDeployer"
  title       = "emisar deployer (MIG rolling replace)"
  description = "Trigger and watch a managed-instance-group rolling replace."
  permissions = [
    "compute.instanceGroupManagers.get",
    "compute.instanceGroupManagers.update",
    "compute.instanceGroups.get",
    "compute.regionOperations.get",
  ]
}

resource "google_project_iam_member" "deployer_role" {
  project = var.project_id
  role    = google_project_iam_custom_role.deployer.id
  member  = "serviceAccount:${google_service_account.deployer.email}"
}

# Recreating MIG instances re-attaches the VM service account, which requires
# the caller be allowed to act as it — scoped to that one SA, never project-wide.
resource "google_service_account_iam_member" "deployer_actas_vm" {
  service_account_id = google_service_account.vm.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.deployer.email}"
}

# Let this repository's workflow runs impersonate the deployer.
resource "google_service_account_iam_member" "deployer_wif" {
  service_account_id = google_service_account.deployer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}
