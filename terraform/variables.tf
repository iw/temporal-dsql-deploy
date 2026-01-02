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

variable "opensearch_collection_name" {
  type        = string
  description = "Name for the OpenSearch Serverless collection"
  default     = "temporal-visibility"
}

variable "dsql_cluster_name" {
  type        = string
  description = "Name for the DSQL cluster"
  default     = "temporal-dsql-cluster"
}

variable "opensearch_deletion_protection" {
  type        = bool
  description = "Enable deletion protection for OpenSearch Serverless collection"
  default     = false
}
