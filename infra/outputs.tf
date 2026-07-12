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

output "next_steps" {
  description = "The remaining path to production, in order. Full commands: README «Cutover runbook»."
  value       = <<-EOT
    1. Merge through the required «Required - CI» check. Main-only CD reuses that
       exact CI workflow, publishes its tested portal image, uploads this commit's
       infra configuration to HCP Terraform, and produces the reviewable plan.
       FIRST publish only: flip the GHCR
       package to Public, or the unauthenticated instance pull 403s.
    2. Review the complete saved plan and click «Confirm & Apply» in HCP
       Terraform. CD never calls apply. The run blocks until the MIG is updated
       and stable; the LB routes only /readyz-healthy VMs. Rollback is another
       reviewed plan using a previous digest.
    3. BEFORE any traffic move (README has the commands):
         a. import the Fly database into Cloud SQL (freeze Fly writes first);
         b. optional: add Fly's SECRET_KEY_BASE as a NEW secret version so
            operator sessions survive the cutover;
         c. at GoDaddy (still the live DNS): add the FOUR cert DNS-auth CNAMEs
            (apex, www, mta-sts, registry) + CAA `0 issue "pki.goog"`, wait for
            the certs to be ACTIVE, then
            verify: curl --resolve ${var.domain}:443:<lb_ipv4> https://${var.domain}/readyz
         d. registry.${var.domain} can go live INDEPENDENTLY, before any traffic
            move: add its A/AAAA at GoDaddy (terraform output
            pack_registry_godaddy_records), verify
            https://registry.${var.domain}/v1/catalog.json, then flip the
            catalog base (packctl --base-url default + EMISAR_PACK_CATALOG_URL —
            see packs/PUBLISHING.md «Serving domain»)
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
