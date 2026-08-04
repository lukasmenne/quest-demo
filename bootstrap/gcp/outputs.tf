output "workload_identity_provider" {
  description = "Put this in the GCP_WORKLOAD_IDENTITY_PROVIDER GitHub Actions variable (not a secret — a WIF provider resource name isn't sensitive on its own), used with google-github-actions/auth."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "service_account_email" {
  description = "Put this in the GCP_SERVICE_ACCOUNT GitHub Actions variable, used with google-github-actions/auth."
  value       = google_service_account.github_actions_terraform.email
}
