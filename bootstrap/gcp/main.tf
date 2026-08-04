data "google_project" "current" {
  project_id = var.gcp_project_id
}

resource "google_project_service" "iamcredentials" {
  project = var.gcp_project_id
  service = "iamcredentials.googleapis.com"
}

resource "google_project_service" "sts" {
  project = var.gcp_project_id
  service = "sts.googleapis.com"
}

resource "google_iam_workload_identity_pool" "github" {
  project                   = var.gcp_project_id
  workload_identity_pool_id = var.pool_id
  display_name              = "GitHub Actions"
  description               = "Identity pool for GitHub Actions OIDC"

  depends_on = [google_project_service.iamcredentials, google_project_service.sts]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.gcp_project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = var.provider_id
  display_name                       = "GitHub Actions"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
    "attribute.event_name" = "assertion.event_name"
  }

  # Restrict to pushes on main and any pull_request run in this repo. Uses the `repository`
  # claim (plain "owner/repo"), not `sub` — unlike AWS/Azure, this is unaffected by GitHub's
  # April 2026 immutable subject claims change, since `repository` was always a separate,
  # stable claim rather than a substring of `sub`.
  attribute_condition = "assertion.repository == \"${var.github_org}/${var.github_repo}\" && (assertion.ref == \"refs/heads/main\" || assertion.event_name == \"pull_request\")"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account" "github_actions_terraform" {
  project      = var.gcp_project_id
  account_id   = var.service_account_id
  display_name = "GitHub Actions Terraform"
}

resource "google_service_account_iam_member" "github_actions_wif_binding" {
  service_account_id = google_service_account.github_actions_terraform.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_org}/${var.github_repo}"
}

resource "google_project_iam_member" "github_actions_terraform" {
  for_each = toset(var.project_roles)
  project  = var.gcp_project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.github_actions_terraform.email}"
}
