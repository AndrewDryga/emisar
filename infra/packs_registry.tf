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

# Public read for artifact objects — the reason the bucket exists. The built-in
# `roles/storage.objectViewer` also grants `storage.objects.list`, which exposes
# an anonymous bucket index. Use a project custom role with only GET so every
# published object remains fetchable by its exact URL while the bucket root is
# not a discovery surface.
resource "google_project_iam_custom_role" "pack_registry_public_reader" {
  project     = var.project_id
  role_id     = "packRegistryPublicReader"
  title       = "Pack Registry Public Object Reader"
  description = "Anonymous GET access to published pack-registry objects without bucket listing."
  permissions = ["storage.objects.get"]
  stage       = "GA"
}

resource "google_storage_bucket_iam_member" "pack_registry_public_read" {
  bucket = google_storage_bucket.pack_registry.name
  role   = google_project_iam_custom_role.pack_registry_public_reader.name
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
# the public GET-only binding above (IAM is additive).
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

# Let the main workflow's pack-publish job impersonate the publisher through the
# keyless GitHub WIF pool (deploy.tf) — the publish job mints a short-lived
# access token for packctl; no key exists anywhere.
resource "google_service_account_iam_member" "pack_publisher_wif" {
  service_account_id = google_service_account.pack_publisher.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}

# ── Serving domain: registry.<domain> on the SHARED HTTPS LB ──────────────────
# Vendor-neutral artifact URLs: published catalogs bake tarball URLs into
# immutable objects forever, so they should name OUR domain, not a Google
# endpoint we can never rotate away from. The host rides the existing LB
# (lb.tf adds a host rule → this backend bucket), so it costs no extra
# forwarding rules and pack installs never depend on the app tier — the LB
# serves the bucket directly. storage.googleapis.com URLs keep working
# unchanged; this is an additive read-side alias.
resource "google_compute_backend_bucket" "pack_registry" {
  name        = "emisar-pack-registry-backend"
  bucket_name = google_storage_bucket.pack_registry.name

  # CDN stays OFF until publish stamps Cache-Control per object class: the
  # mutable catalog.json/suggest.json pointers carry no cache-busting names,
  # so edge-caching them would pin a stale catalog at the edge for hours.
  # (The content-addressed tarballs are perfectly cacheable — flipping this
  # on is worth it only WITH that metadata discipline.)
  enable_cdn = false
  depends_on = [google_project_service.apis]
}

# Its OWN managed cert, not a new SAN on the emisar cert (lb.tf): adding a SAN
# re-provisions the existing cert, briefly risking apex TLS mid-migration for a
# hostname that has nothing to do with the console. The shared certificate map
# selects certs purely by SNI, so an independent cert + map entry is the
# isolation-preserving way to add a served hostname.
resource "google_certificate_manager_dns_authorization" "registry" {
  name        = "emisar-dnsauth-registry"
  domain      = "registry.${var.domain}"
  description = "DNS authorization for the pack-registry serving domain"
  depends_on  = [google_project_service.apis]
}

resource "google_certificate_manager_certificate" "registry" {
  name = "emisar-cert-registry"
  managed {
    domains            = ["registry.${var.domain}"]
    dns_authorizations = [google_certificate_manager_dns_authorization.registry.id]
  }
  depends_on = [google_project_service.apis]
}

resource "google_certificate_manager_certificate_map_entry" "registry" {
  name         = "emisar-certmap-entry-registry"
  map          = google_certificate_manager_certificate_map.emisar.name
  certificates = [google_certificate_manager_certificate.registry.id]
  hostname     = "registry.${var.domain}"
}
