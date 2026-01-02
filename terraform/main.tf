# Minimal DSQL-only Terraform configuration
# This version provisions only Aurora DSQL cluster for use with local Elasticsearch

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# Data source for current AWS account
data "aws_caller_identity" "current" {}

# Aurora DSQL Cluster
resource "aws_dsql_cluster" "this" {
  deletion_protection_enabled = false

  tags = {
    Name        = "${var.project_name}-dsql"
    Environment = "development"
    ManagedBy   = "terraform"
    Project     = var.project_name
  }
}
