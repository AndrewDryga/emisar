# DNSSEC keys are read back from the zone so we can print the DS record to submit
# at the registrar. Empty until the zone's keys generate (first apply).
data "google_dns_keys" "emisar" {
  managed_zone = google_dns_managed_zone.emisar.id
}

output "nameservers" {
  description = "Set these as emisar.dev's NS records at the registrar (GoDaddy) to delegate DNS to Cloud DNS."
  value       = google_dns_managed_zone.emisar.name_servers
}

output "dnssec_ds_record" {
  description = "DS record to add at the registrar (GoDaddy → DNSSEC) to complete the chain of trust. Do this LAST, after the NS delegation is confirmed resolving."
  value       = try(data.google_dns_keys.emisar.key_signing_keys[0].ds_record, "(pending — re-run `terraform apply` / `terraform output` after the zone's keys generate)")
}

output "next_steps" {
  description = "One-time cutover steps after the first apply."
  value       = <<-EOT
    1. Point emisar.dev's nameservers at this zone (GoDaddy → Nameservers → "I'll use my own"):
         ${join("\n         ", google_dns_managed_zone.emisar.name_servers)}
    2. Wait for delegation to propagate, then verify:
         dig +short NS emisar.dev        # the four Cloud DNS nameservers above
         dig +short emisar.dev           # still ${var.fly_ipv4}
         dig +short MX emisar.dev        # Google Workspace
         curl -sS -o /dev/null -w '%%{http_code}\n' https://emisar.dev/   # 200
    3. ONLY after resolution is confirmed, add the DS record at the registrar to finish DNSSEC:
         terraform output dnssec_ds_record
       then check `dig +dnssec emisar.dev` returns the AD (authenticated-data) flag.
    4. Ramp DMARC once aggregate reports confirm Postmark + Workspace align:
         var.dmarc_policy: none → quarantine → reject.
  EOT
}
