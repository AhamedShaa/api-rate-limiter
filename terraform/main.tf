terraform {
  required_version = ">= 1.3.0"
  # This means: "only run if Terraform version is 1.3.0 or higher"
  # Protects against old versions that might behave differently

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
      # ~> 5.0 means: "5.x is fine, but not 6.0"
      # Protects against breaking changes in future provider versions
    }
  }
}

provider "aws" {
  region = var.aws_region
  # var.aws_region means: "read the value from variables.tf"
  # We never hardcode region — makes the project portable
}