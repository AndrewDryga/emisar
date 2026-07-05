terraform {
  # State in a versioned, private GCS bucket in the emisar project — self-contained
  # in GCP, no external SaaS to provision. The bucket enforces uniform bucket-level
  # access + public-access-prevention and keeps object versions for recovery.
  # Migrate to another backend later with `terraform init -migrate-state`.
  backend "gcs" {
    bucket = "emisar-tfstate"
    prefix = "dns"
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
    "artifactregistry.googleapis.com",
    "monitoring.googleapis.com",
    "logging.googleapis.com",
    "iap.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}

# ── Private container registry (SOC 2: private + vulnerability-scanned) ───────
# emisar's image lives in Artifact Registry, not public GHCR — a security product
# ships a private image, and AR + Container Analysis scans it for CVEs. The VM
# service account pulls it with `roles/artifactregistry.reader` (iam.tf).
resource "google_artifact_registry_repository" "emisar" {
  location      = var.region
  repository_id = "emisar"
  format        = "DOCKER"
  description   = "emisar portal container images"

  docker_config {
    immutable_tags = false
  }

  depends_on = [google_project_service.apis]
}
