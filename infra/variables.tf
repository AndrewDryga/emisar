variable "project_id" {
  type        = string
  description = "GCP project ID to deploy emisar into."
}

variable "region" {
  type        = string
  description = "GCP region for the regional MIG + Cloud SQL."
  default     = "us-central1"

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]+$", var.region))
    error_message = "region must be a GCP region name such as us-central1."
  }
}

variable "zones" {
  type        = list(string)
  description = "Distinct zones used by the regional MIG and its per-zone steady-state reservations. Every zone must belong to var.region and instance_count must cover every zone."
  default     = ["us-central1-a", "us-central1-c"]

  validation {
    condition = (
      length(var.zones) >= 2 &&
      length(distinct(var.zones)) == length(var.zones) &&
      alltrue([for zone in var.zones : startswith(zone, "${var.region}-")])
    )
    error_message = "zones must contain at least two distinct zones inside region."
  }
}

variable "domain" {
  type        = string
  description = "Public hostname, no trailing dot (served by the HTTPS LB)."
  default     = "emisar.dev"

  validation {
    condition = (
      !endswith(var.domain, ".") &&
      can(regex("^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}$", var.domain))
    )
    error_message = "domain must be a lowercase DNS hostname without a trailing dot."
  }
}

variable "subnet_cidr" {
  type        = string
  description = "CIDR for the dedicated emisar subnet."
  default     = "10.82.0.0/24"

  validation {
    condition = (
      can(cidrhost(var.subnet_cidr, 1)) &&
      !strcontains(var.subnet_cidr, ":") &&
      try(cidrhost(var.subnet_cidr, 0) == split("/", var.subnet_cidr)[0], false)
    )
    error_message = "subnet_cidr must be a canonical IPv4 network CIDR such as 10.82.0.0/24."
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
  description = "Location of the public pack-registry bucket."
  default     = "US"
}

variable "release_cookie_ready" {
  description = "Use the separate RELEASE_COOKIE secret. Keep false until release_cookie_value is the currently derived production cookie."
  type        = bool
  default     = false
}

variable "release_cookie_value" {
  description = "Exact RELEASE_COOKIE payload. Required when release_cookie_ready or livebook_enabled is true; derive the current production value so every node remains one cluster."
  type        = string
  sensitive   = true
  ephemeral   = true
  default     = null

  validation {
    condition = (
      (!var.release_cookie_ready && !var.livebook_enabled) ||
      (var.release_cookie_value != null && length(var.release_cookie_value) >= 32)
    )
    error_message = "release_cookie_value must be at least 32 characters when release_cookie_ready or livebook_enabled is true."
  }
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

  validation {
    condition     = var.instance_count >= length(var.zones)
    error_message = "instance_count must be at least the number of zones so every configured zone has a serving instance and reservation."
  }
}

variable "cos_image" {
  type        = string
  description = "Exact Container-Optimized OS image name for portal VMs. Keep this pinned so an unchanged Terraform configuration always boots the same host bytes; update deliberately after reviewing a newer cos-stable image."
  default     = "cos-stable-121-18867-528-7"

  validation {
    condition     = can(regex("^cos-stable-[0-9]+-[0-9]+-[0-9]+-[0-9]+$", var.cos_image))
    error_message = "cos_image must be an exact cos-stable image name, not a moving family."
  }
}

variable "container_image" {
  type        = string
  description = "Fully-qualified portal image on public GHCR, pinned by digest. No default on purpose: CI passes the tested digest into an approval-gated Terraform run; rollback = apply a previous digest."

  validation {
    condition     = can(regex("^ghcr\\.io/andrewdryga/emisar@sha256:[0-9a-f]{64}$", var.container_image))
    error_message = "container_image must be an immutable ghcr.io/andrewdryga/emisar@sha256:<64 hex> digest reference."
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
  description = "Repository whose main CD workflow may assume the pack-publisher identity."
  default     = "AndrewDryga/emisar"
}

variable "mailer_from_email" {
  type        = string
  description = "From address for outbound product mail (MAILER_FROM_EMAIL); unset, the release falls back to no-reply@emisar.dev."
  default     = "hello@emisar.dev"
}

# ── Livebook admin workbench ─────────────────────────────────────────────────
variable "livebook_enabled" {
  type        = bool
  description = "Deploy the private Livebook admin workbench behind Google IAP. Enabling it requires release_cookie_ready and livebook_iap_iam_user."
  default     = false
}

variable "livebook_machine_type" {
  type        = string
  description = "Compute Engine machine type for the optional Livebook instance. Environment sizing is set per-workspace; the default is a small reference configuration."
  default     = "e2-small"

  validation {
    condition     = length(trimspace(var.livebook_machine_type)) > 0
    error_message = "livebook_machine_type must not be empty."
  }
}

variable "livebook_data_disk_size_gb" {
  type        = number
  description = "Persistent Livebook notebook/configuration disk size in GB, set per-workspace."
  default     = 10

  validation {
    condition     = var.livebook_data_disk_size_gb >= 10 && floor(var.livebook_data_disk_size_gb) == var.livebook_data_disk_size_gb
    error_message = "livebook_data_disk_size_gb must be an integer >= 10."
  }
}

variable "livebook_iap_iam_user" {
  type        = string
  description = "Lowercase Google user email allowed through IAP to the Livebook admin workbench. Set as a sensitive HCP Terraform workspace variable; null omits the workbench access grant."
  sensitive   = true
  default     = null

  validation {
    condition = var.livebook_iap_iam_user == null || try(
      var.livebook_iap_iam_user == lower(var.livebook_iap_iam_user) &&
      can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.livebook_iap_iam_user)),
      false,
    )
    error_message = "livebook_iap_iam_user must be null or a lowercase email address."
  }
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
  description = "Cloud SQL machine tier, set per-workspace. Shared-core tiers do not support Query Insights; db-custom-* tiers do."
  default     = "db-custom-1-3840"
}

variable "database_owner_role_ready" {
  type        = bool
  description = "Confirms the PostgreSQL bootstrap and IAM verifier succeeded. False keeps the application MIG at zero for a blank-database bootstrap; restored production databases retain the role and extension."
  default     = false
}

variable "database_operator_iam_user" {
  type        = string
  description = "Lowercase Google user email for the production database operator. Set as a sensitive HCP Terraform workspace variable; null omits personal database access."
  sensitive   = true
  default     = null

  validation {
    condition = var.database_operator_iam_user == null || try(
      var.database_operator_iam_user == lower(var.database_operator_iam_user) &&
      can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.database_operator_iam_user)),
      false,
    )
    error_message = "database_operator_iam_user must be null or a lowercase email address."
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

variable "slack_alert_channel_id" {
  type        = string
  description = "Optional Slack monitoring notification channel that also receives every alert, as a full channel name (projects/<project>/notificationChannels/<id>). Created in the console and referenced by ID because a GCP Slack channel stores an OAuth token Terraform can't round-trip; set it per-workspace (Terraform Cloud variable). Empty routes alerts to email (plus Better Stack paging for the severe subset) only."
  default     = ""

  validation {
    condition     = var.slack_alert_channel_id == "" || can(regex("^projects/[^/]+/notificationChannels/[0-9]+$", var.slack_alert_channel_id))
    error_message = "slack_alert_channel_id must be empty or a full channel name: projects/<project>/notificationChannels/<numeric id>."
  }
}

variable "betterstack_api_token" {
  type        = string
  description = "Better Stack (BetterUptime) API token — the provider credential for the external uptime monitors + public status page (uptime.tf). Same custody as the app secrets: a SENSITIVE Terraform Cloud workspace variable, never a committed value. No default on purpose — the workspace must hold it before any plan runs."
  sensitive   = true
}

variable "oncall_emails" {
  type        = list(string)
  description = "Better Stack on-call rotation, in order — account emails of the people who take incidents (each must already be a Better Stack team member; invites happen out of band). SENSITIVE workspace variable on purpose: the roster AND its size stay out of the public repo. No default — set it in the workspace."
  sensitive   = true

  validation {
    condition     = length(var.oncall_emails) >= 1
    error_message = "oncall_emails needs at least one address — an empty rotation pages no one."
  }
}

variable "betterstack_gcp_paging" {
  type        = bool
  description = "Page the Better Stack on-call for the severe, silent-failure GCP alarms via its Google Monitoring integration (uptime.tf). Requires a PAID Better Stack tier — the free tier returns 403 on google-monitoring-integrations. When false those alarms still email + Slack like the rest, and the external uptime monitors page regardless; flip to true after upgrading."
  default     = false
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
