terraform {
  # State + variables live in Terraform Cloud (org Dryga, project emisar). This
  # matters more than usual: runtime secrets enter as SENSITIVE workspace
  # variables. Provider write-only arguments and ephemeral random values keep
  # payloads out of new state snapshots, but TFC still holds the externally
  # issued credentials and gates them behind workspace RBAC + audit logs. Treat
  # access to this workspace as access to production.
  cloud {
    organization = "Dryga"

    workspaces {
      project = "emisar"
      name    = "emisar"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

data "google_project" "current" {
  project_id = var.project_id
}

# ── APIs ─────────────────────────────────────────────────────────────────────
# Enabling a service needs serviceusage + cloudresourcemanager already on — the
# README bootstrap step turns those on once. disable_on_destroy=false so a
# `terraform destroy` never yanks an API another workload in the project relies on.
resource "google_project_service" "apis" {
  for_each = toset([
    "compute.googleapis.com",
    "dns.googleapis.com",
    "secretmanager.googleapis.com",
    "storage.googleapis.com", # the public pack-registry bucket (packs_registry.tf)
    "certificatemanager.googleapis.com",
    "sqladmin.googleapis.com",
    "servicenetworking.googleapis.com",
    "monitoring.googleapis.com",
    "logging.googleapis.com",
    "iap.googleapis.com",
    # Workload Identity Federation for the GitHub Actions deploy identity
    # (deploy.tf): pool/provider live in iam, the token exchange is sts, and
    # the impersonation call is iamcredentials.
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}
