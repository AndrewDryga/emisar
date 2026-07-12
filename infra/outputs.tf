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

output "deploy_workload_identity_provider" {
  description = "Full WIF provider resource name the CD workflow authenticates against (google-github-actions/auth `workload_identity_provider`)."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "deploy_service_account" {
  description = "Service account the CD workflow impersonates to roll the MIG."
  value       = google_service_account.deployer.email
}

output "pack_registry_bucket" {
  description = "GCS bucket holding the published pack-registry artifacts (the publisher and portal write/read here)."
  value       = google_storage_bucket.pack_registry.name
}

output "pack_registry_base_url" {
  description = "Public HTTPS base URL for pack artifacts — install snippets and the portal catalog loader join paths onto this (e.g. <base>/v1/catalog.json)."
  value       = "https://storage.googleapis.com/${google_storage_bucket.pack_registry.name}"
}

output "next_steps" {
  description = "The remaining path to production, in order. Full commands: README «Cutover runbook»."
  value       = <<-EOT
    1. Publish the portal image (Actions → «CD · Portal» → Run workflow); FIRST
       publish only: flip the GHCR package to Public, or the unauthenticated
       instance pull 403s. container_image tracks :latest by design (one-click
       CD rolls it); the per-build sha-<sha> tags are the rollback pointers.
    2. terraform apply — blocks until the MIG serves /healthz.
    3. BEFORE any traffic move (README has the commands):
         a. import the Fly database into Cloud SQL (freeze Fly writes first);
         b. optional: add Fly's SECRET_KEY_BASE as a NEW secret version so
            operator sessions survive the cutover;
         c. at GoDaddy (still the live DNS): add the three cert DNS-auth CNAMEs
            + CAA `0 issue "pki.goog"`, wait for the cert to be ACTIVE, then
            verify: curl --resolve ${var.domain}:443:<lb_ipv4> https://${var.domain}/healthz
    4. Converge traffic at GoDaddy FIRST (avoids a two-database split-brain
       while NS propagates): lower the A/AAAA TTLs, point A → lb_ipv4 and
       AAAA → lb_ipv6, watch runners reconnect.
    5. Delegate NS at the registrar (now a zero-traffic change):
         ${join("\n         ", google_dns_managed_zone.emisar.name_servers)}
    6. LAST, after NS resolves everywhere: publish the DNSSEC DS
       (terraform output dnssec_ds_record); `dig +dnssec ${var.domain}` shows AD.
       Keep Fly running until traffic drains, then decommission it.
  EOT
}
