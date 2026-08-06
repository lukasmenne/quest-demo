terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  backend "azurerm" {}
}

provider "azurerm" {
  features {}
  skip_provider_registration = true
  subscription_id            = var.subscription_id
  client_id                  = var.client_id
  use_oidc                   = true
  tenant_id                  = var.tenant_id
}

provider "aws" {
  region = var.aws_region

  # Terraform has no way to conditionally skip configuring a declared provider block, so this
  # provider is still configured (and its Configure() step runs) even while enable_aws = false
  # and no aws_* resources exist. Skip the eager STS validation call so a placeholder
  # AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY (required for Configure() to succeed at all) doesn't
  # fail plan/apply before the AWS trial exists. Real per-resource calls during an actual AWS
  # apply still fail loudly on bad credentials, so this doesn't hide anything once enable_aws
  # is flipped on.
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_region_validation      = true
}

provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
}
