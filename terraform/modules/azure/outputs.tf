output "endpoint_url" {
  description = "Public HTTPS endpoint for the Azure deployment (Front Door, managed cert on *.azurefd.net)"
  value       = "https://${azurerm_cdn_frontdoor_endpoint.quest.host_name}"
}
