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
  description = "Public GHCR image the MIG runs — publish it there before apply."
  value       = var.container_image
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

output "packs_workload_identity_provider" {
  description = "Full WIF provider resource name the main-only CD workflow authenticates against for pack publishing (google-github-actions/auth `workload_identity_provider`)."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "pack_registry_bucket" {
  description = "GCS bucket holding the published pack-registry artifacts (the publisher and portal write/read here)."
  value       = google_storage_bucket.pack_registry.name
}

output "pack_registry_base_url" {
  description = "Canonical public HTTPS base URL for pack artifacts — install snippets and the portal catalog loader join paths onto this (e.g. <base>/v1/catalog.json)."
  value       = "https://registry.${var.domain}"
}

output "pack_registry_backing_url" {
  description = "Direct GCS backing URL for storage administration and cutover diagnostics; customer-facing catalogs and installers use pack_registry_base_url."
  value       = "https://storage.googleapis.com/${google_storage_bucket.pack_registry.name}"
}

output "pack_registry_godaddy_records" {
  description = "Records to add at GoDaddy while it is still the live DNS, so registry.<domain> works BEFORE the NS cutover. The dns.tf copies take over once the zone is authoritative."
  value = {
    a         = "registry  A     ${google_compute_global_address.ipv4.address}"
    aaaa      = "registry  AAAA  ${google_compute_global_address.ipv6.address}"
    cert_auth = "${google_certificate_manager_dns_authorization.registry.dns_resource_record[0].name} ${google_certificate_manager_dns_authorization.registry.dns_resource_record[0].type} ${google_certificate_manager_dns_authorization.registry.dns_resource_record[0].data}"
  }
}

output "status_page_url" {
  description = "Public status page (Better Stack). The custom domain resolves once the zone is authoritative — or earlier by adding `status CNAME statuspage.betteruptime.com` at the current registrar; until then the page serves at https://<subdomain>.betteruptime.com."
  value       = "https://status.${var.domain}"
}

output "next_steps" {
  description = "What remains after the 2026-07-12 Fly→GCP cutover, in order."
  value       = <<-EOT
    Cutover executed 2026-07-12 (README «Cutover runbook» is the record).
    Remaining:
    1. After NS delegation resolves everywhere (up to 48 h — verify with
       `dig +trace ${var.domain} NS`): publish the DNSSEC DS at the registrar
       (terraform output dnssec_ds_record); `dig +dnssec ${var.domain}` then
       shows AD. A DS ahead of working delegation takes the domain offline.
    2. Once traffic and email flows are confirmed drained off Fly:
       decommission the Fly app (its database was imported at cutover).
    3. Ongoing: ramp DMARC (var.dmarc_policy none → quarantine → reject) and
       MTA-STS (testing → enforce) on clean reports — dns.tf comments.
  EOT
}
