# New GCP projects don't come with these enabled, and the resources below need them.
resource "google_project_service" "iam" {
  service            = "iam.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "secretmanager" {
  service            = "secretmanager.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "run" {
  service            = "run.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "compute" {
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

# Newly-enabled APIs can take a few seconds to propagate; resources created against them
# immediately in the same apply have been known to 403 otherwise.
resource "time_sleep" "gcp_api_propagation" {
  depends_on = [
    google_project_service.iam, google_project_service.secretmanager,
    google_project_service.run, google_project_service.compute
  ]
  create_duration = "30s"
}

resource "google_service_account" "quest_run" {
  account_id   = "quest-run"
  display_name = "Quest Cloud Run runtime"

  depends_on = [time_sleep.gcp_api_propagation]
}

resource "google_secret_manager_secret" "secret_word" {
  secret_id = "quest-secret-word"

  replication {
    auto {}
  }

  depends_on = [time_sleep.gcp_api_propagation]
}

resource "google_secret_manager_secret_version" "secret_word" {
  secret      = google_secret_manager_secret.secret_word.id
  secret_data = var.secret_word
}

resource "google_secret_manager_secret_iam_member" "quest_run" {
  secret_id = google_secret_manager_secret.secret_word.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.quest_run.email}"
}

resource "google_cloud_run_v2_service" "quest" {
  name     = "quest-app"
  location = var.region
  # Cloud Run's default ingress works, but its built-in *.run.app path doesn't forward a
  # header bin/004's /loadbalanced check can detect (Google documents only
  # X-Cloud-Trace-Context, X-Forwarded-For, and X-Forwarded-Proto as added to the request --
  # nothing naming Google the way its own response headers do). Restricting ingress to the
  # external HTTPS Load Balancer below (via the serverless NEG) both fixes that and means the
  # app genuinely can't be reached except through the load balancer, same as the other clouds.
  ingress = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
  labels  = var.tags

  template {
    service_account = google_service_account.quest_run.email

    containers {
      image = var.image

      ports {
        container_port = var.app_port
      }

      env {
        name = "SECRET_WORD"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.secret_word.secret_id
            version = "latest"
          }
        }
      }
    }
  }

  depends_on = [google_secret_manager_secret_iam_member.quest_run, time_sleep.gcp_api_propagation]
}

resource "google_cloud_run_v2_service_iam_member" "invoker" {
  project  = google_cloud_run_v2_service.quest.project
  location = google_cloud_run_v2_service.quest.location
  name     = google_cloud_run_v2_service.quest.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# --- External HTTPS Load Balancer (managed cert on a sslip.io hostname, same trick as Azure) ---
#
# Reserve the static IP first so the sslip.io hostname (derived from it) can be known ahead of
# the managed cert's domain list. Structure follows Google's own reference module
# (GoogleCloudPlatform/terraform-google-lb-http, serverless_negs submodule) rather than guessing.

resource "google_compute_global_address" "lb" {
  name = "quest-lb-ip"

  depends_on = [time_sleep.gcp_api_propagation]
}

resource "google_compute_region_network_endpoint_group" "quest" {
  name                  = "quest-neg"
  region                = var.region
  network_endpoint_type = "SERVERLESS"

  cloud_run {
    service = google_cloud_run_v2_service.quest.name
  }
}

resource "google_compute_backend_service" "quest" {
  name                  = "quest-backend"
  load_balancing_scheme = "EXTERNAL_MANAGED"

  backend {
    group = google_compute_region_network_endpoint_group.quest.id
  }
}

resource "google_compute_managed_ssl_certificate" "quest" {
  name = "quest-cert"

  managed {
    domains = ["${google_compute_global_address.lb.address}.sslip.io"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_compute_url_map" "quest" {
  name            = "quest-url-map"
  default_service = google_compute_backend_service.quest.id
}

resource "google_compute_target_https_proxy" "quest" {
  name             = "quest-https-proxy"
  url_map          = google_compute_url_map.quest.id
  ssl_certificates = [google_compute_managed_ssl_certificate.quest.id]
}

resource "google_compute_global_forwarding_rule" "https" {
  name                  = "quest-https-forwarding-rule"
  target                = google_compute_target_https_proxy.quest.id
  ip_address            = google_compute_global_address.lb.id
  port_range            = "443"
  load_balancing_scheme = "EXTERNAL_MANAGED"
}

# HTTP -> HTTPS redirect, matching how Azure/AWS both ultimately serve HTTPS only.
resource "google_compute_url_map" "redirect" {
  name = "quest-http-redirect"

  default_url_redirect {
    https_redirect         = true
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    strip_query            = false
  }
}

resource "google_compute_target_http_proxy" "quest" {
  name    = "quest-http-proxy"
  url_map = google_compute_url_map.redirect.id
}

resource "google_compute_global_forwarding_rule" "http" {
  name                  = "quest-http-forwarding-rule"
  target                = google_compute_target_http_proxy.quest.id
  ip_address            = google_compute_global_address.lb.id
  port_range            = "80"
  load_balancing_scheme = "EXTERNAL_MANAGED"
}
