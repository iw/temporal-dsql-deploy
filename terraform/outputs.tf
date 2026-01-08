output "dsql_cluster_arn" {
  description = "ARN of the Aurora DSQL cluster"
  value       = aws_dsql_cluster.this.arn
}

output "dsql_cluster_identifier" {
  description = "Identifier of the Aurora DSQL cluster"
  value       = aws_dsql_cluster.this.identifier
}

output "dsql_public_endpoint" {
  description = "Public endpoint for Aurora DSQL cluster"
  value       = "${aws_dsql_cluster.this.identifier}.dsql.${var.region}.on.aws"
}

# Environment variables for easy configuration
output "environment_variables" {
  description = "Environment variables for Temporal configuration"
  value = {
    # DSQL Configuration
    TEMPORAL_SQL_HOST        = "${aws_dsql_cluster.this.identifier}.dsql.${var.region}.on.aws"
    TEMPORAL_SQL_PORT        = "5432"
    TEMPORAL_SQL_USER        = "admin"
    TEMPORAL_SQL_DATABASE    = "postgres"
    TEMPORAL_SQL_PLUGIN      = "dsql"
    TEMPORAL_SQL_TLS_ENABLED = "true"
    TEMPORAL_SQL_IAM_AUTH    = "true"

    # AWS Configuration
    AWS_REGION = var.region

    # Elasticsearch Configuration (Local Docker)
    TEMPORAL_ELASTICSEARCH_HOST   = "elasticsearch"
    TEMPORAL_ELASTICSEARCH_PORT   = "9200"
    TEMPORAL_ELASTICSEARCH_SCHEME = "http"
  }
}
