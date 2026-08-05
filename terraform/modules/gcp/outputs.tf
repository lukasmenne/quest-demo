output "endpoint_url" {
  description = "Public HTTPS endpoint for the GCP deployment (Cloud Run managed cert on *.run.app)"
  value       = google_cloud_run_v2_service.quest.uri
}
