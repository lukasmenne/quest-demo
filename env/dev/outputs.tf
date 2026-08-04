output "azure_endpoint_url" {
  description = "Public HTTPS endpoint for the Azure deployment"
  value       = module.azure.endpoint_url
}

output "aws_endpoint_url" {
  description = "Public HTTPS endpoint for the AWS deployment (null until enable_aws = true)"
  value       = try(module.aws[0].endpoint_url, null)
}

output "gcp_endpoint_url" {
  description = "Public HTTPS endpoint for the GCP deployment (null until enable_gcp = true)"
  value       = try(module.gcp[0].endpoint_url, null)
}
