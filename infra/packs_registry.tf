# ── Pack registry — the ONE deliberate public-read surface ────────────────────
# Everything else in this stack is private by default (AGENTS.md §1). This bucket
# is the explicit, documented exception: `emisar pack install <id>` runs
# UNAUTHENTICATED (an operator or an LLM pulling a pack over MCP has no GCP creds),
# so the published artifacts — catalog.json, suggest.json, the JSON schemas, and
# the immutable pack tarballs — must be world-readable over plain HTTPS.
#
# The safety argument for opening it: NOTHING account-scoped, secret, or
# customer-owned is ever written here. The only bytes are pack tarballs (already
# public source in packs/) and their catalog/suggest/schema metadata. Install
# safety does not rest on the transport — snippets pin `--hash sha256:...` and the
# runner rejects any tampered tarball after download — so a public read surface
# adds no trust that the content hash doesn't already carry.
resource "google_storage_bucket" "pack_registry" {
  name     = var.pack_registry_bucket
  location = var.pack_registry_location
  project  = var.project_id

  # IAM-only (no per-object ACLs): the public-read grant below is one auditable
  # IAM binding, not ACLs scattered per object that could silently leak a private
  # object if the publisher ever wrote one.
  uniform_bucket_level_access = true

  # We INTEND public read (the allUsers binding below), so this must stay
  # `inherited`, not `enforced`. It's called out explicitly so a future org policy
  # tightening reads as a deliberate override for this one bucket, not an oversight.
  public_access_prevention = "inherited"

  # Preserve every published pack version/hash (the task's core requirement). With
  # versioning on, an overwrite of a mutable object (the latest catalog.json
  # pointer) keeps the prior generation fetchable, and there is deliberately NO
  # lifecycle delete rule — historical tarballs and versioned catalog snapshots are
  # never garbage-collected. Recovery of an accidentally-overwritten object is
  # `gcloud storage cp gs://<bucket>/<obj>#<generation> …` (see README).
  versioning {
    enabled = true
  }

  labels = {
    surface = "public-pack-registry"
  }

  # This bucket IS the published registry — every historical pack version lives
  # here and unauthenticated installs resolve against it. Destroying it breaks
  # every prior install snippet, so it is destroy-guarded (AGENTS.md §3);
  # force_destroy stays false so `terraform destroy` can't empty it either.
  force_destroy = false
  lifecycle {
    prevent_destroy = true
  }
}

# Public read for artifact objects — the reason the bucket exists. `objectViewer`
# grants GET on objects only (not bucket config, not writes, not listing the
# bucket via allUsers), which is exactly what `emisar pack install` needs.
resource "google_storage_bucket_iam_member" "pack_registry_public_read" {
  bucket = google_storage_bucket.pack_registry.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

# ── Publisher identity — least-privilege, objects only ───────────────────────
# The CI/publishing job writes artifacts as this SA. It gets `objectUser`
# (objects create/get/list/delete), NOT `objectAdmin` or a project-wide storage
# role. It can't be create-only: republishing the mutable pointers
# (catalog.json / suggest.json) REPLACES the live object, and GCS requires
# `storage.objects.delete` for an overwrite even with versioning on — a
# create-only `objectCreator` 403s the second publish. History still survives a
# replace: versioning archives the prior live generation and there is no
# lifecycle delete rule. Accepted residual: this SA *could* explicitly delete
# archived generations — install trust rests on the pinned `--hash` in the
# snippets, not on the registry. Reads for post-publish verification go through
# the public objectViewer binding above (IAM is additive).
resource "google_service_account" "pack_publisher" {
  account_id   = "emisar-pack-publisher"
  display_name = "emisar pack registry publisher"
  project      = var.project_id
}

resource "google_storage_bucket_iam_member" "pack_registry_publisher" {
  bucket = google_storage_bucket.pack_registry.name
  role   = "roles/storage.objectUser"
  member = "serviceAccount:${google_service_account.pack_publisher.email}"
}

# Let the repo's "CD · Packs" workflow impersonate the publisher through the
# same keyless GitHub WIF pool as the deployer (deploy.tf) — the publish job
# mints a short-lived access token for packctl; no key exists anywhere.
resource "google_service_account_iam_member" "pack_publisher_wif" {
  service_account_id = google_service_account.pack_publisher.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}
