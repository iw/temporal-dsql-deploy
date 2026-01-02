provider "aws" {
  region = var.region
}

# Get available AZs in the region
data "aws_availability_zones" "available" {
  state = "available"
}

# Get current AWS caller identity for OpenSearch access policy
data "aws_caller_identity" "current" {}

locals {
  name = var.project_name
  tags = merge(var.tags, { Project = var.project_name })
}

# -----------------------------
# VPC + private subnets
# -----------------------------

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.tags, { Name = "${local.name}-vpc" })
}

resource "aws_subnet" "private" {
  for_each = { for idx, cidr in var.private_subnet_cidrs : idx => cidr }

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value
  availability_zone       = data.aws_availability_zones.available.names[each.key]
  map_public_ip_on_launch = false

  tags = merge(local.tags, { Name = "${local.name}-private-${each.key}" })
}

# -----------------------------
# Security groups
# -----------------------------

resource "aws_security_group" "client_vpn" {
  name        = "${local.name}-client-vpn-sg"
  description = "Client VPN security group"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "OpenVPN TLS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.allowed_client_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${local.name}-client-vpn-sg" })
}

resource "aws_security_group" "dsql_vpce" {
  name        = "${local.name}-dsql-vpce-sg"
  description = "Interface VPC Endpoint SG for Aurora DSQL"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "PostgreSQL from VPN clients"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.client_vpn_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${local.name}-dsql-vpce-sg" })
}

resource "aws_security_group" "opensearch" {
  name        = "${local.name}-opensearch-sg"
  description = "Security group for OpenSearch cluster"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTPS from VPN clients"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.client_vpn_cidr]
  }

  ingress {
    description = "HTTPS from private subnets"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.private_subnet_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${local.name}-opensearch-sg" })
}

# -----------------------------
# Aurora DSQL cluster
# -----------------------------

resource "aws_dsql_cluster" "this" {
  deletion_protection_enabled = var.dsql_deletion_protection_enabled
  kms_encryption_key          = var.dsql_kms_encryption_key_arn
  tags                        = merge(local.tags, { Name = "${local.name}-dsql" })
}

# -----------------------------
# OpenSearch Provisioned Domain
# -----------------------------

# Create subnet group for OpenSearch
resource "aws_opensearch_domain" "temporal_visibility" {
  domain_name    = "${var.project_name}-visibility"
  engine_version = var.opensearch_engine_version

  cluster_config {
    instance_type            = var.opensearch_instance_type
    instance_count           = var.opensearch_instance_count
    dedicated_master_enabled = var.opensearch_dedicated_master_enabled
    master_instance_type     = var.opensearch_master_instance_type
    master_instance_count    = var.opensearch_master_instance_count
    zone_awareness_enabled   = var.opensearch_zone_awareness_enabled

    dynamic "zone_awareness_config" {
      for_each = var.opensearch_zone_awareness_enabled ? [1] : []
      content {
        availability_zone_count = length(var.private_subnet_cidrs)
      }
    }
  }

  vpc_options {
    subnet_ids         = [for s in aws_subnet.private : s.id]
    security_group_ids = [aws_security_group.opensearch.id]
  }

  ebs_options {
    ebs_enabled = true
    volume_type = var.opensearch_ebs_volume_type
    volume_size = var.opensearch_ebs_volume_size
  }

  encrypt_at_rest {
    enabled = true
  }

  node_to_node_encryption {
    enabled = true
  }

  domain_endpoint_options {
    enforce_https       = true
    tls_security_policy = "Policy-Min-TLS-1-2-2019-07"
  }

  advanced_security_options {
    enabled                        = true
    anonymous_auth_enabled         = false
    internal_user_database_enabled = var.opensearch_internal_user_database_enabled

    master_user_options {
      master_user_arn = var.opensearch_master_user_arn != "" ? var.opensearch_master_user_arn : data.aws_caller_identity.current.arn
    }
  }

  access_policies = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = var.opensearch_master_user_arn != "" ? var.opensearch_master_user_arn : data.aws_caller_identity.current.arn
        }
        Action   = "es:*"
        Resource = "arn:aws:es:${var.region}:${data.aws_caller_identity.current.account_id}:domain/${var.project_name}-visibility/*"
      }
    ]
  })

  log_publishing_options {
    cloudwatch_log_group_arn = aws_cloudwatch_log_group.opensearch_slow_logs.arn
    log_type                 = "SEARCH_SLOW_LOGS"
    enabled                  = var.opensearch_slow_logs_enabled
  }

  log_publishing_options {
    cloudwatch_log_group_arn = aws_cloudwatch_log_group.opensearch_index_slow_logs.arn
    log_type                 = "INDEX_SLOW_LOGS"
    enabled                  = var.opensearch_index_slow_logs_enabled
  }

  log_publishing_options {
    cloudwatch_log_group_arn = aws_cloudwatch_log_group.opensearch_error_logs.arn
    log_type                 = "ES_APPLICATION_LOGS"
    enabled                  = var.opensearch_error_logs_enabled
  }

  tags = merge(local.tags, { Name = "${local.name}-opensearch" })

  depends_on = [
    aws_cloudwatch_log_group.opensearch_slow_logs,
    aws_cloudwatch_log_group.opensearch_index_slow_logs,
    aws_cloudwatch_log_group.opensearch_error_logs,
  ]
}

# CloudWatch Log Groups for OpenSearch
resource "aws_cloudwatch_log_group" "opensearch_slow_logs" {
  name              = "/aws/opensearch/domains/${var.project_name}-visibility/search-slow-logs"
  retention_in_days = var.opensearch_log_retention_days
  tags              = local.tags
}

resource "aws_cloudwatch_log_group" "opensearch_index_slow_logs" {
  name              = "/aws/opensearch/domains/${var.project_name}-visibility/index-slow-logs"
  retention_in_days = var.opensearch_log_retention_days
  tags              = local.tags
}

resource "aws_cloudwatch_log_group" "opensearch_error_logs" {
  name              = "/aws/opensearch/domains/${var.project_name}-visibility/error-logs"
  retention_in_days = var.opensearch_log_retention_days
  tags              = local.tags
}

# CloudWatch Log Resource Policy for OpenSearch
resource "aws_cloudwatch_log_resource_policy" "opensearch" {
  policy_name = "${var.project_name}-opensearch-logs"

  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "es.amazonaws.com"
        }
        Action = [
          "logs:PutLogEvents",
          "logs:CreateLogGroup",
          "logs:CreateLogStream"
        ]
        Resource = "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:*"
      }
    ]
  })
}

# -----------------------------
# PrivateLink Interface Endpoint to the DSQL cluster
# -----------------------------

resource "aws_vpc_endpoint" "dsql" {
  vpc_id            = aws_vpc.this.id
  vpc_endpoint_type = "Interface"

  service_name = aws_dsql_cluster.this.vpc_endpoint_service_name

  subnet_ids         = [for s in aws_subnet.private : s.id]
  security_group_ids = [aws_security_group.dsql_vpce.id]

  private_dns_enabled = true

  tags = merge(local.tags, { Name = "${local.name}-dsql-vpce" })
}

# -----------------------------
# Client VPN endpoint (aws provider 6.26.0 style)
# -----------------------------

resource "aws_ec2_client_vpn_endpoint" "this" {
  description            = "${local.name} client vpn"
  server_certificate_arn = var.client_vpn_server_certificate_arn
  client_cidr_block      = var.client_vpn_cidr
  vpc_id                 = aws_vpc.this.id

  split_tunnel       = true
  transport_protocol = "tcp"

  security_group_ids = [aws_security_group.client_vpn.id]

  # Configure DNS servers for private DNS resolution
  dns_servers = [cidrhost(var.vpc_cidr, 2)]

  connection_log_options {
    enabled = false
  }

  dynamic "authentication_options" {
    for_each = var.client_vpn_authentication_options
    content {
      type                       = authentication_options.value.type
      root_certificate_chain_arn = try(authentication_options.value.root_certificate_chain_arn, null)
      saml_provider_arn          = try(authentication_options.value.saml_provider_arn, null)
    }
  }

  tags = merge(local.tags, { Name = "${local.name}-client-vpn" })
}

resource "aws_ec2_client_vpn_network_association" "this" {
  for_each = aws_subnet.private

  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.this.id
  subnet_id              = each.value.id
}

resource "aws_ec2_client_vpn_authorization_rule" "vpc" {
  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.this.id
  target_network_cidr    = aws_vpc.this.cidr_block
  authorize_all_groups   = true
}
