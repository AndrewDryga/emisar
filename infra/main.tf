terraform {
  # State in a versioned, private GCS bucket in the emisar project — self-contained
  # in GCP, no external SaaS to provision. The bucket enforces uniform bucket-level
  # access + public-access-prevention and keeps object versions for recovery. State
  # holds no secrets here (the only sensitive-looking output, the DNSSEC DS, is
  # public). Migrate to another backend later with `terraform init -migrate-state`.
  backend "gcs" {
    bucket = "emisar-tfstate"
    prefix = "dns"
  }
}

provider "google" {
  project = var.project_id
}

# Cloud DNS API. Enabling a service needs serviceusage + cloudresourcemanager
# already on — Terraform can't bootstrap those into an empty project itself:
#   gcloud services enable serviceusage.googleapis.com cloudresourcemanager.googleapis.com --project=<project>
resource "google_project_service" "dns" {
  service            = "dns.googleapis.com"
  disable_on_destroy = false
}
