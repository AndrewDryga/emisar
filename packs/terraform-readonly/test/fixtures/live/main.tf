terraform {
  required_version = ">= 1.0"
}

resource "terraform_data" "database" {
  input = "packtest-canary-terraform-resource-secret-e9c4"
}

output "password" {
  value     = "packtest-canary-terraform-state-secret-8d6a"
  sensitive = true
}
