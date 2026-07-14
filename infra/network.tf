# ── Dedicated VPC ────────────────────────────────────────────────────────────
# A dedicated network instead of the project default keeps emisar's firewall and
# NAT blast radius obvious and small (the default VPC often carries broad
# allow-internal rules). SOC 2: explicit network segmentation.
resource "google_compute_network" "emisar" {
  name                    = "emisar-vpc"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.apis]
}

resource "google_compute_subnetwork" "emisar" {
  name          = "emisar-${var.region}"
  region        = var.region
  ip_cidr_range = var.subnet_cidr
  network       = google_compute_network.emisar.id
  # Private Google Access: instances with no external IP still reach Google APIs
  # (Secret Manager, Cloud Logging, Compute) over Google's backbone; the public
  # GHCR image pull egresses through Cloud NAT below.
  private_ip_google_access = true

  # Flow logs are an audit/forensics control (who talked to whom).
  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# ── Private Service Access — the peering that gives Cloud SQL a private IP ─────
# Cloud SQL with no public IP is reachable only over this VPC peering, so the
# database is never exposed to the internet (SOC 2: no public data-store surface).
resource "google_compute_global_address" "private_service" {
  name          = "emisar-psa"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.emisar.id
}

resource "google_service_networking_connection" "private_service" {
  network                 = google_compute_network.emisar.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_service.name]
  depends_on              = [google_project_service.apis]
}

# ── Cloud Router + NAT: egress for private instances, no per-VM external IP ────
resource "google_compute_router" "emisar" {
  name       = "emisar-router"
  region     = var.region
  network    = google_compute_network.emisar.id
  depends_on = [google_project_service.apis]
}

resource "google_compute_router_nat" "emisar" {
  name                               = "emisar-nat"
  router                             = google_compute_router.emisar.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = google_compute_subnetwork.emisar.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# ── Firewall: only the Google LB + health-check ranges reach the app port ─────
resource "google_compute_firewall" "lb_to_app" {
  name      = "emisar-allow-lb"
  network   = google_compute_network.emisar.id
  direction = "INGRESS"
  allow {
    protocol = "tcp"
    ports    = [tostring(local.portal_port)]
  }
  # Google global LB proxies + health checkers.
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = ["emisar"]
}

# SSH ONLY via Identity-Aware Proxy — no 0.0.0.0/0 SSH. Reach a box with:
#   gcloud compute ssh <instance> --tunnel-through-iap
resource "google_compute_firewall" "iap_ssh" {
  name      = "emisar-allow-iap-ssh"
  network   = google_compute_network.emisar.id
  direction = "INGRESS"
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["emisar"]
}

# Erlang distribution between portal instances: epmd (4369) + the pinned dist
# range (rel/env.sh.eex clustering) so the nodes form one BEAM cluster — Phoenix
# PubSub + Presence span machines, so a runner socket on one node is reachable
# from another and runs don't strand in :sent. Scoped tag→tag; nothing else
# reaches these ports.
resource "google_compute_firewall" "cluster_dist" {
  name      = "emisar-allow-cluster"
  network   = google_compute_network.emisar.id
  direction = "INGRESS"
  allow {
    protocol = "tcp"
    ports    = ["4369", "9100-9105"]
  }
  source_tags = ["emisar"]
  target_tags = ["emisar"]
}
