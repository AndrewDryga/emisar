# emisar infrastructure — Google Cloud DNS.
#
# This module owns ONE thing: the authoritative public DNS zone for emisar.dev,
# hosted on Cloud DNS. emisar's compute, load balancer, and TLS terminate on
# Fly.io — there is deliberately no GCP serving stack here (that is the shape of
# ../onlytty/infra, whose app runs on GCP; emisar's does not). Keeping DNS in
# Terraform gives us a reviewed, versioned zone instead of hand-clicks in a
# registrar UI.

terraform {
  required_version = ">= 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
