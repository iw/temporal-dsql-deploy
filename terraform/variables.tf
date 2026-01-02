variable "project_name" {
  type        = string
  description = "Prefix for resource names"
}

variable "region" {
  type        = string
  default     = "eu-west-1"
  description = "AWS region for DSQL cluster"
}
