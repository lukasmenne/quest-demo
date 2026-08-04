output "github_actions_role_arn" {
  description = "Put this in the AWS_ROLE_ARN GitHub Actions variable (not a secret — an IAM role ARN isn't sensitive on its own), used with aws-actions/configure-aws-credentials."
  value       = aws_iam_role.github_actions_terraform.arn
}

output "oidc_provider_arn" {
  description = "ARN of the GitHub OIDC provider registered in this account."
  value       = aws_iam_openid_connect_provider.github.arn
}
