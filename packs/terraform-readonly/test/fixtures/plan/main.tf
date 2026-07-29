# A workspace whose plan is entirely creates, built only from the builtin
# terraform_data resource so `init` needs no provider download and the behavior
# cases stay offline.
#
# The canary values exist to prove the projection never emits attribute or
# output values: `region` is a KNOWN non-sensitive output, so the plan really
# does carry its value, and the case asserts the canary never reaches stdout.

terraform {
  required_version = ">= 1.0"
}

resource "terraform_data" "workers" {
  count = 2
  input = "packtest-canary-terraform-plan-attribute-3f18"
}

resource "terraform_data" "database" {
  input = "database"
}

output "region" {
  value = "packtest-canary-terraform-plan-output-9c3d"
}

output "admin_token" {
  value     = "packtest-canary-terraform-plan-secret-4b71"
  sensitive = true
}
