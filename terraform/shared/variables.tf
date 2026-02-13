variable "project_name" {
  type        = string
  description = "Prefix for resource names (e.g. 'temporal-dev')"
}

variable "region" {
  type        = string
  default     = "eu-west-1"
  description = "AWS region for all shared resources"
}

variable "create_dynamodb_tables" {
  type        = bool
  default     = false
  description = "Create DynamoDB tables for distributed rate limiting and connection leasing. Only needed for multi-instance deployments (ECS). Not required for local Docker development."
}
