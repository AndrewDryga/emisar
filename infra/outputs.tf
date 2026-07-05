# DNSSEC keys are read back from the zone so we can print the DS record to submit
# at the registrar. Empty until the zone's keys generate (first apply).
data "google_dns_keys" "emisar" {
  managed_zone = google_dns_managed_zone.emisar.id
}

output "lb_ipv4" {
  description = "Global anycast IPv4 of the HTTPS load balancer (the apex A record points here)."
  value       = google_compute_global_address.ipv4.address
}

output "lb_ipv6" {
  description = "Global anycast IPv6 of the HTTPS load balancer (the apex AAAA record points here)."
  value       = google_compute_global_address.ipv6.address
}

output "url" {
  description = "Public URL once DNS resolves and the managed cert provisions."
  value       = "https://${var.domain}"
}

output "container_image" {
  description = "Artifact Registry path the MIG runs. Push the emisar image here before apply."
  value       = local.container_image
}

output "db_private_ip" {
  description = "Cloud SQL private IP (the DATABASE_URL secret is built from this)."
  value       = google_sql_database_instance.emisar.private_ip_address
}

output "nameservers" {
  description = "Set these as emisar.dev's NS records at the registrar (GoDaddy) to delegate DNS to Cloud DNS."
  value       = google_dns_managed_zone.emisar.name_servers
}

output "dnssec_ds_record" {
  description = "DS record to add at the registrar to complete DNSSEC. Do it LAST, after NS delegation resolves."
  value       = try(data.google_dns_keys.emisar.key_signing_keys[0].ds_record, "(pending — re-run after the zone's keys generate)")
}

output "next_steps" {
  description = "One-time steps to bring the GCP stack up (nothing is applied by preparing this code)."
  value       = <<-EOT
    1. Push the portal image to Artifact Registry:
         gcloud auth configure-docker ${var.region}-docker.pkg.dev
         docker build -t ${local.container_image} portal
         docker push ${local.container_image}
    2. Add the required secret VALUES (never in state — database-url is filled by apply):
         printf %s "$(mix phx.gen.secret)" | gcloud secrets versions add emisar-secret-key-base --data-file=- --project=${var.project_id}
         # then emisar-paddle-api-key / -webhook-secret / -client-token (or set disable_billing=true),
         # and optionally emisar-postmark-* / -sentry-dsn / -mixpanel-token.
    3. terraform apply (creates the VPC, Cloud SQL, MIG, LB, cert, and DNS zone).
    4. Delegate the domain — set these NS at the registrar:
         ${join("\n         ", google_dns_managed_zone.emisar.name_servers)}
    5. After NS resolves + the managed cert is ACTIVE, publish the DNSSEC DS at the registrar:
         terraform output dnssec_ds_record
       then GET https://${var.domain}/healthz should return 200 and `dig +dnssec ${var.domain}` shows the AD flag.
  EOT
}
