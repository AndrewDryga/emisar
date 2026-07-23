# MTA-STS is intentionally isolated from the portal in its own public-read
# bucket. Only the standardized policy object is published there.
resource "google_storage_bucket" "mta_sts" {
  project  = var.project_id
  name     = "${var.project_id}-mta-sts"
  location = var.region

  uniform_bucket_level_access = true
  public_access_prevention    = "inherited"
  force_destroy               = false

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_storage_bucket_iam_member" "mta_sts_public_read" {
  bucket = google_storage_bucket.mta_sts.name
  role   = google_project_iam_custom_role.pack_registry_public_reader.name
  member = "allUsers"
}

resource "google_storage_bucket_object" "mta_sts" {
  name          = ".well-known/mta-sts.txt"
  bucket        = google_storage_bucket.mta_sts.name
  content       = file("${path.module}/templates/mta-sts.txt")
  content_type  = "text/plain"
  cache_control = "no-store"
}

resource "google_compute_backend_bucket" "mta_sts" {
  name        = "emisar-mta-sts-backend"
  bucket_name = google_storage_bucket.mta_sts.name
  enable_cdn  = false

  depends_on = [google_storage_bucket_object.mta_sts]
}

