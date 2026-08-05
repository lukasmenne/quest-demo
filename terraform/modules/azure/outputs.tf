output "endpoint_url" {
  description = "Public HTTPS endpoint for the Azure deployment (Azure CDN, managed cert on *.azureedge.net)"
  value       = "https://${azurerm_cdn_endpoint.quest.fqdn}"
}
