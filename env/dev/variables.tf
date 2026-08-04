variable "client_id" {}
variable "subscription_id" {}
variable "tenant_id" {}

variable "image" {
  description = "Container image reference, e.g. ghcr.io/lukasmenne/quest-demo:sha-abc123"
  type        = string
}

variable "secret_word" {
  description = "Value for the SECRET_WORD environment variable, exercised by /secret_word"
  type        = string
  sensitive   = true
}

variable "app_port" {
  description = "Port the app listens on inside the container"
  type        = number
  default     = 3000
}

variable "tags" {
  description = "Resource tags/labels applied across all clouds"
  type        = map(string)
  default     = { project = "quest" }
}

variable "enable_aws" {
  description = "Whether to instantiate the AWS module. False until AWS credentials/trial exist."
  type        = bool
  default     = false
}

variable "enable_gcp" {
  description = "Whether to instantiate the GCP module. False until GCP credentials/trial exist."
  type        = bool
  default     = false
}

variable "aws_region" {
  description = "AWS region for the ECS/ALB/CloudFront deployment"
  type        = string
  default     = "us-east-1"
}

variable "gcp_project_id" {
  description = "GCP project ID for the Cloud Run deployment"
  type        = string
  default     = "project-db8ba5d7-2499-46a0-b86"
}

variable "gcp_region" {
  description = "GCP region for the Cloud Run deployment"
  type        = string
  default     = "us-central1"
}
