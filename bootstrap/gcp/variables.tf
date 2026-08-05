variable "gcp_project_id" {
  description = "GCP project ID that will host the Workload Identity Pool and service account."
  type        = string
  default     = "project-db8ba5d7-2499-46a0-b86"
}

variable "github_org" {
  description = "GitHub organization or user that owns the repository."
  type        = string
  default     = "lukasmenne"
}

variable "github_repo" {
  description = "GitHub repository name."
  type        = string
  default     = "quest-demo"
}

variable "pool_id" {
  description = "Workload Identity Pool ID."
  type        = string
  default     = "github-actions-pool"
}

variable "provider_id" {
  description = "Workload Identity Pool Provider ID."
  type        = string
  default     = "github-actions-provider"
}

variable "service_account_id" {
  description = "Service account ID (the part before @) impersonated by GitHub Actions."
  type        = string
  default     = "github-actions-terraform"
}

variable "project_roles" {
  description = "IAM roles granted to the GitHub Actions service account on the project. Defaults to roles/editor for bootstrap convenience -- scope this down once the GCP-managed resources are known. roles/secretmanager.admin and roles/run.admin are required in addition to roles/editor: both Secret Manager and Cloud Run deliberately exclude their own IAM policy management (secretmanager.secrets.setIamPolicy, run.services.setIamPolicy) -- and Secret Manager also excludes secret payload access (secretmanager.versions.access) -- from the basic Editor/Owner roles as a security default, even for the project's own service accounts."
  type        = list(string)
  default     = ["roles/editor", "roles/secretmanager.admin", "roles/run.admin"]
}
