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
  name                       = var.project_name
  tags                       = merge(var.tags, { Project = var.project_name })
  opensearch_collection_name = "${var.project_name}-vis"
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

# -----------------------------
# Aurora DSQL cluster
# -----------------------------

resource "aws_dsql_cluster" "this" {
  deletion_protection_enabled = var.dsql_deletion_protection_enabled
  kms_encryption_key          = var.dsql_kms_encryption_key_arn
  tags                        = merge(local.tags, { Name = "${local.name}-dsql" })
}

# -----------------------------
# OpenSearch Serverless Collection
# -----------------------------

resource "aws_opensearchserverless_security_policy" "encryption" {
  name = "${var.project_name}-encrypt"
  type = "encryption"
  policy = jsonencode({
    Rules = [
      {
        Resource = [
          "collection/${local.opensearch_collection_name}"
        ]
        ResourceType = "collection"
      }
    ]
    AWSOwnedKey = true
  })
}

resource "aws_opensearchserverless_security_policy" "network" {
  name = "${var.project_name}-network"
  type = "network"
  policy = jsonencode([
    {
      Rules = [
        {
          Resource = [
            "collection/${local.opensearch_collection_name}"
          ]
          ResourceType = "collection"
        }
      ]
      AllowFromPublic = true
    }
  ])
}

resource "aws_opensearchserverless_access_policy" "data" {
  name = "${var.project_name}-data"
  type = "data"
  policy = jsonencode([
    {
      Rules = [
        {
          Resource = [
            "collection/${local.opensearch_collection_name}"
          ]
          Permission = [
            "aoss:CreateCollectionItems",
            "aoss:DeleteCollectionItems",
            "aoss:UpdateCollectionItems",
            "aoss:DescribeCollectionItems"
          ]
          ResourceType = "collection"
        },
        {
          Resource = [
            "index/${local.opensearch_collection_name}/*"
          ]
          Permission = [
            "aoss:CreateIndex",
            "aoss:DeleteIndex",
            "aoss:UpdateIndex",
            "aoss:DescribeIndex",
            "aoss:ReadDocument",
            "aoss:WriteDocument"
          ]
          ResourceType = "index"
        }
      ]
      Principal = [
        data.aws_caller_identity.current.arn
      ]
    }
  ])
}

resource "aws_opensearchserverless_collection" "temporal_visibility" {
  name = local.opensearch_collection_name
  type = "SEARCH"

  depends_on = [
    aws_opensearchserverless_security_policy.encryption,
    aws_opensearchserverless_security_policy.network,
    aws_opensearchserverless_access_policy.data
  ]

  tags = merge(local.tags, { Name = "${local.name}-temporal-visibility" })
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
