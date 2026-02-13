variable "project_name" {
  type        = string
  description = "Prefix for resource names (should match shared infrastructure)"
}

variable "region" {
  type        = string
  default     = "eu-west-1"
  description = "AWS region (should match shared infrastructure)"
}
