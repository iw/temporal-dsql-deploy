# ---------------------------------------------------------------------------
# DSQL
# ---------------------------------------------------------------------------

output "copilot_dsql_endpoint" {
  description = "Public endpoint for the Copilot Aurora DSQL cluster"
  value       = "${aws_dsql_cluster.copilot.identifier}.dsql.${var.region}.on.aws"
}

output "copilot_dsql_cluster_identifier" {
  description = "Identifier of the Copilot DSQL cluster"
  value       = aws_dsql_cluster.copilot.identifier
}

output "copilot_dsql_cluster_arn" {
  description = "ARN of the Copilot DSQL cluster"
  value       = aws_dsql_cluster.copilot.arn
}

# ---------------------------------------------------------------------------
# Bedrock Knowledge Base
# ---------------------------------------------------------------------------

output "knowledge_base_id" {
  description = "Bedrock Knowledge Base ID for RAG retrieval"
  value       = awscc_bedrock_knowledge_base.copilot.id
}

output "knowledge_base_arn" {
  description = "Bedrock Knowledge Base ARN"
  value       = awscc_bedrock_knowledge_base.copilot.knowledge_base_arn
}

output "data_source_id" {
  description = "Bedrock Data Source ID for triggering ingestion"
  value       = awscc_bedrock_data_source.copilot_docs.data_source_id
}

output "kb_source_bucket" {
  description = "S3 bucket for KB source documents"
  value       = aws_s3_bucket.kb_source.bucket
}

output "kb_vectors_bucket" {
  description = "S3 Vectors bucket name"
  value       = awscc_s3vectors_vector_bucket.kb.vector_bucket_name
}

output "kb_index_arn" {
  description = "S3 Vectors index ARN"
  value       = awscc_s3vectors_index.kb.index_arn
}

# ---------------------------------------------------------------------------
# General
# ---------------------------------------------------------------------------

output "region" {
  description = "AWS region"
  value       = var.region
}
