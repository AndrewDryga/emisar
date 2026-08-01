# A production-scale plan: 150 resources whose addresses exceed the
# projection's 80-character clip and more outputs than its bounded sample
# keeps, built only from the builtin terraform_data resource so `init` needs
# no provider download and the behavior cases stay offline. The worst-case
# behavior case saves this plan the way CI would; the runner rejects a
# structured result over 8 KiB, so the case's success proves the bounded
# projection fits while the summary still counts everything.

terraform {
  required_version = ">= 1.0"
}

resource "terraform_data" "wide" {
  for_each = toset([
    for index in range(150) :
    format("segment-%03d-with-an-address-long-enough-to-exceed-the-eighty-character-clip", index)
  ])

  input = each.key
}

output "primary_database_connection_endpoint_for_the_payments_service_one" {
  value = length(terraform_data.wide)
}

output "primary_database_connection_endpoint_for_the_payments_service_two" {
  value = length(terraform_data.wide)
}

output "primary_database_connection_endpoint_for_the_payments_service_three" {
  value = length(terraform_data.wide)
}

output "primary_database_connection_endpoint_for_the_payments_service_four" {
  value = length(terraform_data.wide)
}

output "primary_database_connection_endpoint_for_the_payments_service_five" {
  value = length(terraform_data.wide)
}

output "primary_database_connection_endpoint_for_the_payments_service_six" {
  value = length(terraform_data.wide)
}
