# emisar infrastructure — the full GCP deployment, prepared for SOC 2 Type II:
# a global HTTPS load balancer (Google-managed TLS) fronting a regional MIG of
# Container-Optimized OS instances running the portal image from public GHCR,
# backed by private-IP Cloud SQL Postgres, with Secret Manager, least-priv IAM,
# audit logging, monitoring, and the authoritative Cloud DNS zone (DNSSEC).
# Adapted from ../onlytty/infra. LIVE production infrastructure; DNSSEC DS
# publication remains a registrar action gated on resolver convergence.

terraform {
  required_version = ">= 1.10" # `project` in the cloud{} workspaces block

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    betteruptime = {
      source  = "BetterStackHQ/better-uptime"
      version = "~> 0.21"
    }
  }
}
