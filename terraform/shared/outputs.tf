output "dsql_endpoint" {
  description = "Public endpoint for the shared Aurora DSQL cluster"
  value       = "${aws_dsql_cluster.temporal.identifier}.dsql.${var.region}.on.aws"
}

output "dsql_cluster_identifier" {
  description = "Identifier of the Aurora DSQL cluster"
  value       = aws_dsql_cluster.temporal.identifier
}

output "dsql_cluster_arn" {
  description = "ARN of the Aurora DSQL cluster"
  value       = aws_dsql_cluster.temporal.arn
}

output "region" {
  description = "AWS region"
  value       = var.region
}

output "project_name" {
  description = "Project name prefix"
  value       = var.project_name
}

output "rate_limiter_table" {
  description = "DynamoDB rate limiter table name (empty if not created)"
  value       = var.create_dynamodb_tables ? aws_dynamodb_table.rate_limiter[0].name : ""
}

output "conn_lease_table" {
  description = "DynamoDB connection lease table name (empty if not created)"
  value       = var.create_dynamodb_tables ? aws_dynamodb_table.conn_lease[0].name : ""
}
