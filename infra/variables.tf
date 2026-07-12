variable "project_id" {
  type        = string
  description = "GCP project ID to deploy emisar into."
}

variable "region" {
  type        = string
  description = "GCP region for the regional MIG + Cloud SQL."
  default     = "us-central1"
}

variable "zone" {
  type        = string
  description = "Zone the MIG places instances in and the capacity reservation lives in (must be inside var.region). Single-zone by design at the current size — the base-count reservation is what guarantees rollouts and auto-healing can always get instances back; at 2+ instances, zone redundancy means adding zones with a per-zone reservation each (a deliberate change, not a default)."
  default     = "us-central1-a"
}

variable "domain" {
  type        = string
  description = "Public hostname, no trailing dot (served by the HTTPS LB)."
  default     = "emisar.dev"
}

variable "dns_name" {
  type        = string
  description = "Cloud DNS managed-zone DNS name — the apex WITH a trailing dot."
  default     = "emisar.dev."
}

variable "subnet_cidr" {
  type        = string
  description = "CIDR for the dedicated emisar subnet."
  default     = "10.82.0.0/24"

  validation {
    condition     = can(cidrhost(var.subnet_cidr, 1))
    error_message = "subnet_cidr must be a valid IPv4 CIDR block."
  }
}

# ── Pack registry (the one public-read bucket) ────────────────────────────────
variable "pack_registry_bucket" {
  type        = string
  description = "GCS bucket name for public pack-registry artifacts (catalog.json, suggest.json, JSON schemas, immutable pack tarballs). Bucket names are GLOBALLY unique — override if the default is taken."
  default     = "emisar-pack-registry"
}

variable "pack_registry_location" {
  type        = string
  description = "Location for the pack-registry bucket. A multi-region (US/EU/ASIA) gives world-wide read locality for unauthenticated `emisar pack install`; a single region is cheaper if installs are regional."
  default     = "US"
}

# ── Compute ───────────────────────────────────────────────────────────────────
variable "machine_type" {
  type        = string
  description = "Compute Engine machine type for the portal instances. Environment sizing is set per-workspace (Terraform Cloud variable); this default is the reference configuration."
  default     = "e2-standard-2"
}

variable "instance_count" {
  type        = number
  description = "MIG size, set per-workspace. 2+ forms one BEAM cluster via the GCE libcluster strategy (Emisar.Cluster.GCE), so PubSub/Presence span nodes and runs don't strand; at 1 auto-healing replaces a failed node."
  default     = 2

  validation {
    condition     = var.instance_count >= 1 && floor(var.instance_count) == var.instance_count
    error_message = "instance_count must be an integer >= 1."
  }
}

variable "container_image" {
  type        = string
  description = "Fully-qualified portal image on public GHCR, pinned by digest or immutable `sha-<sha>` tag — NEVER a floating tag like `:latest` (a mutable tag means the registry, not Terraform state, decides what boots on the next auto-heal or scale-out). No default on purpose: CI passes the tested digest into an approval-gated Terraform run; rollback = apply a previous digest."

  validation {
    condition     = can(regex("@sha256:[0-9a-f]{64}$|:sha-[0-9a-f]+$", var.container_image))
    error_message = "container_image must be pinned — a @sha256:<digest> reference or an immutable :sha-<sha> tag, never a floating tag."
  }
}

variable "app_port" {
  type        = number
  description = "Port the portal container listens on (LB backend + health check)."
  default     = 4000

  validation {
    condition     = var.app_port >= 1 && var.app_port <= 65535 && floor(var.app_port) == var.app_port
    error_message = "app_port must be an integer between 1 and 65535."
  }
}

variable "backend_timeout_sec" {
  type        = number
  description = "LB backend timeout (caps a single connection, incl. the runner WebSocket; the runner reconnects)."
  default     = 86400

  validation {
    condition     = var.backend_timeout_sec >= 1 && var.backend_timeout_sec <= 86400 && floor(var.backend_timeout_sec) == var.backend_timeout_sec
    error_message = "backend_timeout_sec must be an integer between 1 and 86400."
  }
}

variable "disable_billing" {
  type        = bool
  description = "Set EMISAR_DISABLE_BILLING=1 in the release (ship the Paddle stub) instead of requiring the paddle-* secrets. Use for an internal/staging tier."
  default     = false
}

variable "github_repository" {
  type        = string
  description = "owner/repo whose GitHub Actions runs may assume the deploy identity (WIF attribute condition + SA binding in deploy.tf)."
  default     = "AndrewDryga/emisar"
}

variable "mailer_from_email" {
  type        = string
  description = "From address for outbound product mail (MAILER_FROM_EMAIL). Prod parity: the Fly deployment sends hello@emisar.dev; unset, the release falls back to no-reply@emisar.dev."
  default     = "hello@emisar.dev"
}

# ── Secrets (SENSITIVE Terraform Cloud workspace variables) ───────────────────
# Externally-issued credentials only — machine secrets (SECRET_KEY_BASE, the DB
# password/URL) are generated in-config and are not variables. "" means "not
# configured": no secret version is created, cloud-init skips the env var, and
# the release treats the feature as off. Paddle is all-or-nothing unless
# disable_billing = true — enforced by a plan-time precondition (compute.tf).

variable "paddle_api_key" {
  type        = string
  description = "Paddle API key (billing). Empty + disable_billing=false fails the plan."
  sensitive   = true
  default     = ""
}

variable "paddle_webhook_secret" {
  type        = string
  description = "Paddle webhook signing secret; required alongside paddle_api_key."
  sensitive   = true
  default     = ""
}

variable "paddle_client_token" {
  type        = string
  description = "Paddle client-side token Paddle.js initializes with on /checkout."
  sensitive   = true
  default     = ""
}

variable "postmark_api_token" {
  type        = string
  description = "Postmark server token (outbound mail). Empty → the release logs mail instead of sending — sign-in magic links won't deliver, so set it for real prod."
  sensitive   = true
  default     = ""
}

variable "postmark_webhook_secret" {
  type        = string
  description = "Postmark bounce/complaint webhook auth. Empty disables the webhook endpoint; sending still works."
  sensitive   = true
  default     = ""
}

variable "sentry_dsn" {
  type        = string
  description = "Sentry DSN. Empty disables error uploads."
  sensitive   = true
  default     = ""
}

variable "mixpanel_token" {
  type        = string
  description = "Mixpanel project token (server-side analytics). Empty keeps analytics off."
  sensitive   = true
  default     = ""
}

# ── Database ──────────────────────────────────────────────────────────────────
variable "db_tier" {
  type        = string
  description = "Cloud SQL machine tier, set per-workspace. Shared-core tiers (db-f1-micro / db-g1-small) don't support REGIONAL HA or Query Insights; db-custom-* tiers support both."
  default     = "db-custom-1-3840"
}

variable "db_availability_type" {
  type        = string
  description = "Cloud SQL availability type, set per-workspace. REGIONAL runs a synchronous standby with automatic failover and requires a db-custom-* db_tier; ZONAL is single-zone (backups + PITR still apply)."
  default     = "REGIONAL"

  validation {
    condition     = contains(["ZONAL", "REGIONAL"], var.db_availability_type)
    error_message = "db_availability_type must be ZONAL or REGIONAL."
  }
}

variable "db_disk_size_gb" {
  type        = number
  description = "Cloud SQL initial disk size in GB (autoresize is on)."
  default     = 20
}

# ── Monitoring ────────────────────────────────────────────────────────────────
variable "alert_email" {
  type        = string
  description = "Email address that receives monitoring alerts (uptime, DB CPU/disk). No default on purpose — set per-workspace (Terraform Cloud variable), and make sure the mailbox actually exists: alerts to an unprovisioned alias silently bounce."
}

# ── DNS records (email posture) ───────────────────────────────────────────────
variable "dmarc_policy" {
  type        = string
  description = "DMARC enforcement. Ramp it: `none` (monitor via rua) → `quarantine` → `reject` once reports confirm Postmark + Workspace align."
  default     = "none"

  validation {
    condition     = contains(["none", "quarantine", "reject"], var.dmarc_policy)
    error_message = "dmarc_policy must be one of: none, quarantine, reject."
  }
}

variable "dmarc_rua" {
  type        = string
  description = "DMARC aggregate-report (rua) address as a mailto: URI."
  default     = "mailto:dmarc@emisar.dev"
}

variable "caa_issuers" {
  type        = list(string)
  description = "CAs allowed to issue certs for the apex AND every subdomain (CAA is inherited). The Google-managed LB cert and the BetterUptime status page both use Let's Encrypt / pki.goog — list every CA in use before adding a subdomain on another host."
  default     = ["letsencrypt.org", "pki.goog"]
}
