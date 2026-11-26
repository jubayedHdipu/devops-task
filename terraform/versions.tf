terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }

  # Remote State Backend (S3 + DynamoDB State Locking)
  # Uncomment and configure bucket/table names after bootstrapping state storage:
  #
  # backend "s3" {
  #   bucket         = "jubayedhdipu-devops-task-tfstate"
  #   key            = "prod/terraform.tfstate"
  #   region         = "ap-southeast-1"
  #   dynamodb_table = "devops-task-tfstate-lock"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
      Repository  = "github.com/jubayedHdipu/devops-task"
    }
  }
}