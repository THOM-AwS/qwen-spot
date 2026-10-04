terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Credentials come from AWS_PROFILE (local) or OIDC (GitHub Actions).
  # bucket and region are supplied at init: terraform init -backend-config=backend.hcl
  # (see backend.hcl.example); in CI from the TF_STATE_BUCKET and TF_STATE_REGION secrets.
  backend "s3" {
    key          = "qwen-spot/main.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project = "qwen-spot"
    }
  }
}
