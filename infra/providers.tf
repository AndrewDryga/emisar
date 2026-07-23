provider "google" {
  project = var.project_id
  region  = var.region
}

provider "betteruptime" {
  api_token = var.betterstack_api_token
}
