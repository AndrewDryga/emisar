# DNSSEC keys are read back from the zone so the published registrar DS can be
# verified and future key rotations can be coordinated safely.
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
  description = "Public production URL."
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
  description = "Authoritative Cloud DNS nameservers configured at the registrar."
  value       = google_dns_managed_zone.emisar.name_servers
}

output "dnssec_ds_record" {
  description = "Key-signing DS published at the registrar; keep it aligned during future DNSSEC rotations."
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
  description = "Direct GCS backing URL for storage administration; customer-facing catalogs and installers use pack_registry_base_url."
  value       = "https://storage.googleapis.com/${google_storage_bucket.pack_registry.name}"
}

output "status_page_url" {
  description = "Public status page served by Better Stack on the custom domain."
  value       = "https://status.${var.domain}"
}
