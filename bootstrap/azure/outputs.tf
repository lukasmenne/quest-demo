output "client_id" {
  description = "Put this in the ARM_CLIENT_ID GitHub Actions variable (not a secret — OIDC means there's no client secret to protect), used by azure/login and the azurerm provider's use_oidc."
  value       = azuread_application.github_actions_terraform.client_id
}

output "tenant_id" {
  description = "Put this in the ARM_TENANT_ID GitHub Actions variable."
  value       = var.tenant_id
}

output "subscription_id" {
  description = "Put this in the ARM_SUBSCRIPTION_ID GitHub Actions variable."
  value       = var.subscription_id
}

output "tfstate_resource_group_name" {
  description = "Put this in the AZURE_TFSTATE_RESOURCE_GROUP GitHub Actions variable."
  value       = azurerm_resource_group.tfstate.name
}

output "tfstate_storage_account_name" {
  description = "Put this in the AZURE_TFSTATE_STORAGE_ACCOUNT GitHub Actions variable."
  value       = azurerm_storage_account.tfstate.name
}

output "tfstate_container_name" {
  description = "Put this in the AZURE_TFSTATE_CONTAINER GitHub Actions variable."
  value       = azurerm_storage_container.tfstate.name
}
