# Shared infrastructure — long-lived resources used across all profiles.
#
# These resources are provisioned once and reused. They should NOT be destroyed
# during normal development cycles. The DSQL cluster and DynamoDB tables persist
# across profile switches, service restarts, and schema resets.
#
# Usage:
#   tdeploy infra apply-shared

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

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# Aurora DSQL cluster — primary persistence for all Temporal profiles
# ---------------------------------------------------------------------------
resource "aws_dsql_cluster" "temporal" {
  deletion_protection_enabled = true

  tags = {
    Name        = "${var.project_name}-dsql"
    Environment = "development"
    ManagedBy   = "terraform"
    Project     = var.project_name
    Lifecycle   = "long-lived"
  }

  lifecycle {
    prevent_destroy = true
  }
}

# ---------------------------------------------------------------------------
# DynamoDB — distributed rate limiter (token bucket)
# ---------------------------------------------------------------------------
resource "aws_dynamodb_table" "rate_limiter" {
  count = var.create_dynamodb_tables ? 1 : 0

  name         = "${var.project_name}-dsql-rate-limiter"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"

  attribute {
    name = "pk"
    type = "S"
  }

  ttl {
    attribute_name = "ttl_epoch"
    enabled        = true
  }

  tags = {
    Name        = "${var.project_name}-dsql-rate-limiter"
    Environment = "development"
    ManagedBy   = "terraform"
    Project     = var.project_name
    Lifecycle   = "long-lived"
  }

  lifecycle {
    prevent_destroy = true
  }
}

# ---------------------------------------------------------------------------
# DynamoDB — distributed connection lease (slot blocks)
# ---------------------------------------------------------------------------
resource "aws_dynamodb_table" "conn_lease" {
  count = var.create_dynamodb_tables ? 1 : 0

  name         = "${var.project_name}-dsql-conn-lease"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"

  attribute {
    name = "pk"
    type = "S"
  }

  ttl {
    attribute_name = "ttl_epoch"
    enabled        = true
  }

  tags = {
    Name        = "${var.project_name}-dsql-conn-lease"
    Environment = "development"
    ManagedBy   = "terraform"
    Project     = var.project_name
    Lifecycle   = "long-lived"
  }

  lifecycle {
    prevent_destroy = true
  }
}
