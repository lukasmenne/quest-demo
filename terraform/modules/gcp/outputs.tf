output "endpoint_url" {
  description = "Public HTTPS endpoint for the GCP deployment (external HTTPS Load Balancer, managed cert on a sslip.io hostname)"
  value       = "https://${google_compute_global_address.lb.address}.sslip.io"
}
