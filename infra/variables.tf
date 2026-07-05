variable "project_id" {
  type        = string
  description = "GCP project ID that hosts the Cloud DNS managed zone."
}

variable "domain" {
  type        = string
  description = "Apex domain, no trailing dot (e.g. emisar.dev)."
  default     = "emisar.dev"
}

variable "dns_name" {
  type        = string
  description = "Cloud DNS managed-zone DNS name — the apex WITH a trailing dot (e.g. emisar.dev.)."
  default     = "emisar.dev."
}

# emisar serves from Fly.io; these are its dedicated LB IPs the apex points at.
# If Fly ever reissues the dedicated IPs, update them here — nowhere else.
variable "fly_ipv4" {
  type        = string
  description = "Fly.io dedicated IPv4 for the apex A record (emisar's load balancer)."
  default     = "37.16.18.178"
}

variable "fly_ipv6" {
  type        = string
  description = "Fly.io dedicated IPv6 for the apex AAAA record."
  default     = "2a09:8280:1::11e:a273:0"
}

variable "dmarc_policy" {
  type        = string
  description = "DMARC enforcement. Ramp it: `none` (monitor via rua only) → `quarantine` → `reject`, moving on only once aggregate reports confirm Postmark + Google Workspace both align. Jumping straight to reject can silently drop legitimate mail."
  default     = "none"

  validation {
    condition     = contains(["none", "quarantine", "reject"], var.dmarc_policy)
    error_message = "dmarc_policy must be one of: none, quarantine, reject."
  }
}

variable "dmarc_rua" {
  type        = string
  description = "DMARC aggregate-report (rua) address as a mailto: URI. Point it at a monitored inbox on the domain, or a DMARC service such as Postmark's free monitor. Reports are useless unread — this is how you learn it's safe to ramp the policy."
  default     = "mailto:dmarc@emisar.dev"
}

variable "caa_issuers" {
  type        = list(string)
  description = "CAs allowed to issue certificates for the apex AND every subdomain — CAA at the apex is inherited by subdomains that lack their own. Both emisar's Fly cert and the BetterUptime status page issue via Let's Encrypt, so this is `letsencrypt.org`. Before pointing a NEW subdomain at a host that uses a different CA, add that CA here or its cert renewal will fail."
  default     = ["letsencrypt.org"]
}
