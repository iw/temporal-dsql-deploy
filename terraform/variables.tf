variable "project_name" {
  type        = string
  description = "Prefix for resource names"
}

variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "vpc_cidr" {
  type    = string
  default = "10.50.0.0/16"
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.50.10.0/24", "10.50.11.0/24"]
}

variable "client_vpn_cidr" {
  type        = string
  description = "CIDR assigned to VPN clients"
  default     = "10.254.0.0/22"
}

variable "client_vpn_server_certificate_arn" {
  type        = string
  description = "ACM certificate ARN for the Client VPN endpoint"
}

variable "client_vpn_authentication_options" {
  description = <<EOT
Provide one or more auth options. Common patterns:
- Mutual TLS:
  - type = "certificate-authentication"
  - root_certificate_chain_arn = "arn:aws:acm:..."
- SAML:
  - type = "federated-authentication"
  - saml_provider_arn = "arn:aws:iam::...:saml-provider/..."
EOT

  type = list(object({
    type                       = string
    root_certificate_chain_arn = optional(string)
    saml_provider_arn          = optional(string)
  }))

  validation {
    condition     = length(var.client_vpn_authentication_options) > 0
    error_message = "At least one authentication option must be provided for the Client VPN endpoint."
  }

  validation {
    condition = alltrue([
      for auth in var.client_vpn_authentication_options :
      contains(["certificate-authentication", "federated-authentication"], auth.type)
    ])
    error_message = "Authentication type must be either 'certificate-authentication' or 'federated-authentication'."
  }
}

variable "allowed_client_cidrs" {
  type        = list(string)
  description = "Who can reach the Client VPN listener (TCP/443)"
  default     = ["0.0.0.0/0"]
}

variable "dsql_deletion_protection_enabled" {
  type    = bool
  default = true
}

variable "dsql_kms_encryption_key_arn" {
  type        = string
  description = "KMS key ARN or \"AWS_OWNED_KMS_KEY\""
  default     = "AWS_OWNED_KMS_KEY"
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "environment" {
  type        = string
  description = "Environment name (e.g., development, staging, production)"
  default     = "development"
}

# OpenSearch Provisioned Domain Configuration
variable "opensearch_engine_version" {
  type        = string
  description = "OpenSearch engine version"
  default     = "OpenSearch_2.11"
}

variable "opensearch_instance_type" {
  type        = string
  description = "Instance type for OpenSearch data nodes"
  default     = "t3.small.search"
}

variable "opensearch_instance_count" {
  type        = number
  description = "Number of OpenSearch data nodes"
  default     = 2
}

variable "opensearch_dedicated_master_enabled" {
  type        = bool
  description = "Enable dedicated master nodes for OpenSearch"
  default     = false
}

variable "opensearch_master_instance_type" {
  type        = string
  description = "Instance type for OpenSearch master nodes"
  default     = "t3.small.search"
}

variable "opensearch_master_instance_count" {
  type        = number
  description = "Number of OpenSearch master nodes"
  default     = 3
}

variable "opensearch_zone_awareness_enabled" {
  type        = bool
  description = "Enable zone awareness for OpenSearch"
  default     = true
}

variable "opensearch_ebs_volume_type" {
  type        = string
  description = "EBS volume type for OpenSearch"
  default     = "gp3"
}

variable "opensearch_ebs_volume_size" {
  type        = number
  description = "EBS volume size in GB for OpenSearch"
  default     = 20
}

variable "opensearch_internal_user_database_enabled" {
  type        = bool
  description = "Enable internal user database for OpenSearch"
  default     = false
}

variable "opensearch_master_user_arn" {
  type        = string
  description = "ARN of the master user for OpenSearch (defaults to current caller identity)"
  default     = ""
}

variable "opensearch_slow_logs_enabled" {
  type        = bool
  description = "Enable slow logs for OpenSearch"
  default     = true
}

variable "opensearch_index_slow_logs_enabled" {
  type        = bool
  description = "Enable index slow logs for OpenSearch"
  default     = true
}

variable "opensearch_error_logs_enabled" {
  type        = bool
  description = "Enable error logs for OpenSearch"
  default     = true
}

variable "opensearch_log_retention_days" {
  type        = number
  description = "CloudWatch log retention in days for OpenSearch logs"
  default     = 7
}
