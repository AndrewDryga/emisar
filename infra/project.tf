data "google_project" "current" {
  project_id = var.project_id
}

# Enabling a service needs serviceusage + cloudresourcemanager already on. The
# README bootstrap step turns those on once. disable_on_destroy=false prevents a
# destroy from yanking an API another workload in the project relies on.
resource "google_project_service" "apis" {
  for_each = toset([
    "compute.googleapis.com",
    "dns.googleapis.com",
    "secretmanager.googleapis.com",
    "storage.googleapis.com", # the public pack-registry bucket (pack_registry.tf)
    "certificatemanager.googleapis.com",
    "sqladmin.googleapis.com",
    "servicenetworking.googleapis.com",
    "monitoring.googleapis.com",
    "logging.googleapis.com",
    "iap.googleapis.com",
    # Workload Identity Federation for the GitHub Actions deploy identity
    # (github_oidc.tf): pool/provider live in iam, the token exchange is sts, and
    # the impersonation call is iamcredentials.
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
    # google_billing_budget calls this against the project's quota. Without it a
    # fresh apply or a DR rebuild dies on SERVICE_DISABLED, and the budget's
    # depends_on reads as though the ordering were already handled.
    "billingbudgets.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}
