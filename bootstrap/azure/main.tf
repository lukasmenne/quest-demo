data "azurerm_subscription" "current" {}

# --- Remote state storage ---
# env/dev's `backend "azurerm" {}` needs this to already exist, so it's created here rather than
# in env/dev itself (chicken-and-egg: env/dev's state would need to live somewhere before it
# exists).

resource "azurerm_resource_group" "tfstate" {
  name     = var.tfstate_resource_group_name
  location = var.tfstate_location
}

resource "azurerm_storage_account" "tfstate" {
  name                     = var.tfstate_storage_account_name
  resource_group_name      = azurerm_resource_group.tfstate.name
  location                 = azurerm_resource_group.tfstate.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"

  blob_properties {
    versioning_enabled = true
  }
}

resource "azurerm_storage_container" "tfstate" {
  name                  = var.tfstate_container_name
  storage_account_id    = azurerm_storage_account.tfstate.id
  container_access_type = "private"
}

# --- GitHub Actions OIDC application ---

resource "azuread_application" "github_actions_terraform" {
  display_name = var.app_display_name
}

resource "azuread_service_principal" "github_actions_terraform" {
  client_id = azuread_application.github_actions_terraform.client_id
}

# Restrict to pushes on main and any pull_request run in this repo — mirrors the AWS/GCP
# bootstrap trust conditions. Uses the immutable subject format (owner/repo carry their numeric
# IDs, e.g. repo:lukasmenne@81255942/quest-demo@1322257032:pull_request) — see
# github_owner_id/github_repo_id.
resource "azuread_application_federated_identity_credential" "pull_request" {
  application_id = azuread_application.github_actions_terraform.id
  display_name   = "github-actions-pull-request"
  description    = "GitHub Actions OIDC - pull_request events"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:${var.github_org}@${var.github_owner_id}/${var.github_repo}@${var.github_repo_id}:pull_request"
}

resource "azuread_application_federated_identity_credential" "main_branch" {
  application_id = azuread_application.github_actions_terraform.id
  display_name   = "github-actions-main-branch"
  description    = "GitHub Actions OIDC - push to main"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:${var.github_org}@${var.github_owner_id}/${var.github_repo}@${var.github_repo_id}:ref:refs/heads/main"
}

# --- Role assignments ---
# Contributor on the subscription (env/dev provisions resource groups, VMSS, LB, Front Door,
# etc. across the subscription) plus Storage Blob Data Contributor on the state account
# specifically (data-plane access to read/write the state blob, which Contributor alone doesn't
# grant).

resource "azurerm_role_assignment" "contributor" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Contributor"
  principal_id         = azuread_service_principal.github_actions_terraform.object_id
}

resource "azurerm_role_assignment" "storage_blob_data_contributor" {
  scope                = azurerm_storage_account.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azuread_service_principal.github_actions_terraform.object_id
}
