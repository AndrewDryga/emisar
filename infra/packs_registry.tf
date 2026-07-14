# ── Pack registry: the one deliberate public-read surface ───────────────────
resource "google_storage_bucket" "pack_registry" {
  project  = var.project_id
  name     = var.pack_registry_bucket
  location = var.pack_registry_location

  uniform_bucket_level_access = true
  public_access_prevention    = "inherited"
  force_destroy               = false

  versioning {
    enabled = true
  }

  labels = {
    surface = "public-pack-registry"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_project_iam_custom_role" "pack_registry_public_reader" {
  project     = var.project_id
  role_id     = "packRegistryPublicReader"
  title       = "Public Object Reader"
  description = "Anonymous GET access to explicitly public objects without bucket listing."
  permissions = ["storage.objects.get"]
  stage       = "GA"
}

resource "google_storage_bucket_iam_member" "pack_registry_public_read" {
  bucket = google_storage_bucket.pack_registry.name
  role   = google_project_iam_custom_role.pack_registry_public_reader.name
  member = "allUsers"
}

resource "google_service_account" "pack_publisher" {
  project      = var.project_id
  account_id   = "emisar-pack-publisher"
  display_name = "Emisar Action Pack Registry Publisher"
}

resource "google_storage_bucket_iam_member" "pack_registry_immutable_publisher" {
  bucket = google_storage_bucket.pack_registry.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.pack_publisher.email}"

  condition {
    title       = "create-immutable-registry-objects"
    description = "Create immutable packs, catalog snapshots, and schemas without overwrite or delete permission."
    expression = join(" || ", [
      "resource.name.startsWith('projects/_/buckets/${google_storage_bucket.pack_registry.name}/objects/v1/packs/')",
      "resource.name.startsWith('projects/_/buckets/${google_storage_bucket.pack_registry.name}/objects/v1/catalog/')",
      "resource.name.startsWith('projects/_/buckets/${google_storage_bucket.pack_registry.name}/objects/v1/schemas/')",
    ])
  }
}

resource "google_project_iam_custom_role" "pack_registry_pointer_publisher" {
  project     = var.project_id
  role_id     = "packRegistryPointerPublisher"
  title       = "Pack Registry Pointer Publisher"
  description = "Create, replace, or delete only the live pack-registry pointer objects."
  permissions = [
    "storage.objects.create",
    "storage.objects.delete",
  ]
  stage = "GA"
}

resource "google_storage_bucket_iam_member" "pack_registry_publisher" {
  bucket = google_storage_bucket.pack_registry.name
  role   = google_project_iam_custom_role.pack_registry_pointer_publisher.name
  member = "serviceAccount:${google_service_account.pack_publisher.email}"

  condition {
    title       = "replace-live-registry-pointers"
    description = "Replace or delete only the two live registry pointers; all other published objects are create-only."
    expression = join(" || ", [
      "resource.name == 'projects/_/buckets/${google_storage_bucket.pack_registry.name}/objects/v1/catalog.json'",
      "resource.name == 'projects/_/buckets/${google_storage_bucket.pack_registry.name}/objects/v1/suggest.json'",
    ])
  }
}

resource "google_service_account_iam_member" "pack_publisher_wif" {
  service_account_id = google_service_account.pack_publisher.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.environment/pack-registry-production"
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
# re-provisions the existing cert, briefly risking apex TLS during replacement for a
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
