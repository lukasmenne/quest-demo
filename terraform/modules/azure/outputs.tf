output "endpoint_url" {
  description = "Public HTTPS endpoint for the Azure deployment (Caddy on the VM, Let's Encrypt cert on a sslip.io hostname)"
  value       = "https://${azurerm_public_ip.lb.ip_address}.sslip.io"
}
