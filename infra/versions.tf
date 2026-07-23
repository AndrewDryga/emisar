# emisar infrastructure — the full GCP deployment, prepared for SOC 2 Type II:
# a global HTTPS load balancer (Google-managed TLS) fronting a regional MIG of
# Container-Optimized OS instances running the portal image from public GHCR,
# backed by private-IP Cloud SQL Postgres, with Secret Manager, least-priv IAM,
# audit logging, monitoring, and the authoritative Cloud DNS zone (DNSSEC).
# Adapted from ../onlytty/infra. LIVE production infrastructure; the registrar
# DS is published and the DNSSEC chain validates publicly.

terraform {
  # Keep exact parity with /.tool-versions and the HCP workspace. A broader
  # constraint lets local CI validate with semantics production never uses.
  required_version = "= 1.15.8"

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
