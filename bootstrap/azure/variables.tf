variable "tenant_id" {
  description = "Azure AD tenant ID."
  type        = string
  default     = "6f293262-6e7f-464a-a181-355ba993ef08"
}

variable "subscription_id" {
  description = "Azure subscription ID that GitHub Actions will be granted Contributor on."
  type        = string
  default     = "8f446078-c568-4228-80d3-6bace8d55693"
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

variable "github_owner_id" {
  description = <<-EOT
    GitHub numeric owner (user/org) ID. As of GitHub's April 2026 "immutable subject claims"
    change, OIDC sub claims for this repo are `repo:OWNER@OWNER_ID/REPO@REPO_ID:...` instead of
    `repo:OWNER/REPO:...` — the federated credential subjects below must match the actual format
    the repo issues, or federation silently fails. Check via the repo's Settings > Actions >
    General > OIDC, or a live token's `sub` claim.
  EOT
  type        = string
  default     = "81255942"
}

variable "github_repo_id" {
  description = "GitHub numeric repository ID. See github_owner_id for why this is needed."
  type        = string
  default     = "1322257032"
}

variable "app_display_name" {
  description = "Display name for the Azure AD application (service principal) used by GitHub Actions."
  type        = string
  default     = "github-actions-terraform"
}

variable "tfstate_resource_group_name" {
  description = "Resource group for the Terraform remote state storage account."
  type        = string
  default     = "quest-tfstate"
}

variable "tfstate_location" {
  description = "Azure region for the Terraform remote state storage account."
  type        = string
  default     = "southcentralus"
}

variable "tfstate_storage_account_name" {
  description = "Globally-unique storage account name for Terraform remote state (3-24 lowercase alphanumeric characters)."
  type        = string
  default     = "satfstatequest"
}

variable "tfstate_container_name" {
  description = "Blob container name for Terraform remote state."
  type        = string
  default     = "tfstate"
}
