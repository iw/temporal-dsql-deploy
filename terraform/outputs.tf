output "dsql_cluster_arn" {
  value = aws_dsql_cluster.this.arn
}

output "dsql_vpc_endpoint_service_name" {
  value = aws_dsql_cluster.this.vpc_endpoint_service_name
}

output "dsql_vpc_endpoint_id" {
  value = aws_vpc_endpoint.dsql.id
}

output "dsql_vpc_endpoint_dns_entries" {
  value = aws_vpc_endpoint.dsql.dns_entry
}

output "client_vpn_endpoint_id" {
  value = aws_ec2_client_vpn_endpoint.this.id
}

output "vpc_id" {
  description = "VPC ID for reference"
  value       = aws_vpc.this.id
}

output "private_subnet_ids" {
  description = "Private subnet IDs for troubleshooting"
  value       = [for s in aws_subnet.private : s.id]
}

output "dsql_vpce_security_group_id" {
  description = "Security group ID for DSQL VPC endpoint"
  value       = aws_security_group.dsql_vpce.id
}

output "client_vpn_security_group_id" {
  description = "Security group ID for Client VPN"
  value       = aws_security_group.client_vpn.id
}

output "opensearch_collection_endpoint" {
  description = "OpenSearch Serverless collection endpoint"
  value       = aws_opensearchserverless_collection.temporal_visibility.collection_endpoint
}

output "opensearch_collection_id" {
  description = "OpenSearch Serverless collection ID"
  value       = aws_opensearchserverless_collection.temporal_visibility.id
}

output "opensearch_collection_arn" {
  description = "OpenSearch Serverless collection ARN"
  value       = aws_opensearchserverless_collection.temporal_visibility.arn
}
