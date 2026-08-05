resource "google_service_account" "quest_run" {
  account_id   = "quest-run"
  display_name = "Quest Cloud Run runtime"
}

resource "google_secret_manager_secret" "secret_word" {
  secret_id = "quest-secret-word"

  replication {
    auto {}
  }
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
  ingress  = "INGRESS_TRAFFIC_ALL"
  labels   = var.tags

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

  depends_on = [google_secret_manager_secret_iam_member.quest_run]
}

resource "google_cloud_run_v2_service_iam_member" "invoker" {
  project  = google_cloud_run_v2_service.quest.project
  location = google_cloud_run_v2_service.quest.location
  name     = google_cloud_run_v2_service.quest.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
