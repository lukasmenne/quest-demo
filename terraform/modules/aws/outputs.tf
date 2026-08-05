output "endpoint_url" {
  description = "Public HTTPS endpoint for the AWS deployment (CloudFront, managed cert on *.cloudfront.net)"
  value       = "https://${aws_cloudfront_distribution.quest.domain_name}"
}
