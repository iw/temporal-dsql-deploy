#!/bin/bash
# Setup DynamoDB table for distributed DSQL connection rate limiting
#
# This table coordinates connection rate limiting across all Temporal service
# instances to respect DSQL's cluster-wide 100 connections/sec limit.
#
# Supports two rate limiting modes:
#
# 1. Token Bucket (recommended) - Takes advantage of DSQL's burst capacity
#    Schema: pk=dsql_connect_bucket#<endpoint>
#      - tokens_milli (Number): Current tokens × 1000 (milli-tokens)
#      - last_refill_ms (Number): Last refill timestamp (Unix millis)
#      - rate_milli (Number): Refill rate × 1000 (default: 100_000)
#      - capacity_milli (Number): Max tokens × 1000 (default: 1_000_000)
#      - ttl_epoch (Number): TTL for cleanup if endpoint unused
#
# 2. Per-Second Counter (legacy) - Simple counter per second
#    Schema: pk=dsqlconnect#<endpoint>#<unix_second>
#      - count (Number): Connections created this second
#      - ttl_epoch (Number): TTL for automatic cleanup
#
# Usage:
#   ./scripts/setup-rate-limiter-table.sh [table-name] [region]
#
# Examples:
#   ./scripts/setup-rate-limiter-table.sh                           # Uses defaults
#   ./scripts/setup-rate-limiter-table.sh my-rate-limiter eu-west-1

set -euo pipefail

TABLE_NAME="${1:-temporal-dsql-rate-limiter}"
REGION="${2:-${AWS_REGION:-eu-west-1}}"

echo "Creating DynamoDB table for distributed rate limiting..."
echo "  Table: $TABLE_NAME"
echo "  Region: $REGION"

# Check if table already exists
if aws dynamodb describe-table --table-name "$TABLE_NAME" --region "$REGION" &>/dev/null; then
    echo "✅ Table '$TABLE_NAME' already exists"
    exit 0
fi

# Create table with on-demand billing (pay-per-request)
# Schema:
#   pk (String) - Partition key
#     Token bucket: "dsql_connect_bucket#<endpoint>"
#     Per-second counter: "dsqlconnect#<endpoint>#<unix_second>"
#   ttl_epoch (Number) - TTL attribute for automatic cleanup
aws dynamodb create-table \
    --table-name "$TABLE_NAME" \
    --attribute-definitions \
        AttributeName=pk,AttributeType=S \
    --key-schema \
        AttributeName=pk,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$REGION" \
    --output text \
    --query 'TableDescription.TableArn'

echo "Waiting for table to become active..."
aws dynamodb wait table-exists --table-name "$TABLE_NAME" --region "$REGION"

# Enable TTL on ttl_epoch attribute for automatic cleanup
echo "Enabling TTL on ttl_epoch attribute..."
aws dynamodb update-time-to-live \
    --table-name "$TABLE_NAME" \
    --time-to-live-specification "Enabled=true,AttributeName=ttl_epoch" \
    --region "$REGION" \
    --output text

echo ""
echo "✅ DynamoDB table '$TABLE_NAME' created successfully"
echo ""
echo "To enable distributed rate limiting with token bucket (recommended), add to your .env:"
echo "  DSQL_DISTRIBUTED_RATE_LIMITER_ENABLED=true"
echo "  DSQL_DISTRIBUTED_RATE_LIMITER_TABLE=$TABLE_NAME"
echo "  DSQL_TOKEN_BUCKET_ENABLED=true"
echo "  DSQL_TOKEN_BUCKET_RATE=100"
echo "  DSQL_TOKEN_BUCKET_CAPACITY=1000"
echo ""
echo "For legacy per-second counter mode:"
echo "  DSQL_DISTRIBUTED_RATE_LIMITER_ENABLED=true"
echo "  DSQL_DISTRIBUTED_RATE_LIMITER_TABLE=$TABLE_NAME"
echo "  DSQL_DISTRIBUTED_RATE_LIMITER_LIMIT=100"
echo ""
echo "IAM permissions required for Temporal services:"
echo "  dynamodb:UpdateItem on arn:aws:dynamodb:$REGION:*:table/$TABLE_NAME"
