module "azure" {
  source = "../../terraform/modules/azure"

  image       = var.image
  secret_word = var.secret_word
  app_port    = var.app_port
  tags        = var.tags
}

module "aws" {
  count  = var.enable_aws ? 1 : 0
  source = "../../terraform/modules/aws"

  image       = var.image
  secret_word = var.secret_word
  app_port    = var.app_port
  tags        = var.tags
}

module "gcp" {
  count  = var.enable_gcp ? 1 : 0
  source = "../../terraform/modules/gcp"

  image       = var.image
  secret_word = var.secret_word
  app_port    = var.app_port
  region      = var.gcp_region
  tags        = var.tags
}
