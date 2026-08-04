variable "aws_account_id" {
  description = "Expected AWS account ID. Guards against applying this bootstrap against the wrong account."
  type        = string
  default     = "302186542540"
}

variable "aws_region" {
  description = "AWS region used by the local provider session (IAM/OIDC resources are global, but a region is still required)."
  type        = string
  default     = "us-east-1"
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

variable "role_name" {
  description = "Name of the IAM role assumed by GitHub Actions via OIDC."
  type        = string
  default     = "github-actions-terraform"
}

variable "managed_policy_arns" {
  description = "Managed IAM policy ARNs attached to the GitHub Actions role. Defaults to AdministratorAccess for bootstrap convenience -- scope this down once the AWS-managed resources are known."
  type        = list(string)
  default     = ["arn:aws:iam::aws:policy/AdministratorAccess"]
}
