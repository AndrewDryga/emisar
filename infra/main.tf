terraform {
  # State + variables live in Terraform Cloud (org Dryga, project emisar). This
  # matters more than usual: by decision, runtime secrets enter as SENSITIVE
  # workspace variables and machine secrets are generated in-config, so the
  # workspace's variables and state hold production credentials. TFC encrypts
  # both at rest and gates them behind workspace RBAC + audit logs — treat
  # access to this workspace as access to production (COMPLIANCE.md).
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

# ── APIs ─────────────────────────────────────────────────────────────────────
# Enabling a service needs serviceusage + cloudresourcemanager already on — the
# README bootstrap step turns those on once. disable_on_destroy=false so a
# `terraform destroy` never yanks an API another workload in the project relies on.
resource "google_project_service" "apis" {
  for_each = toset([
    "compute.googleapis.com",
    "dns.googleapis.com",
    "secretmanager.googleapis.com",
    "certificatemanager.googleapis.com",
    "sqladmin.googleapis.com",
    "servicenetworking.googleapis.com",
    "monitoring.googleapis.com",
    "logging.googleapis.com",
    "iap.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}
