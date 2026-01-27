#!/bin/bash
# Setup DynamoDB table for distributed DSQL connection lease tracking
#
# This table coordinates global connection count limiting across all Temporal
# service instances to respect DSQL's 10,000 max connections limit.
#
# Schema:
#   Counter item: pk=dsqllease_counter#<endpoint>
#     - active (Number): current connection count
#     - updated_ms (Number): last update timestamp
#   Lease items: pk=dsqllease#<endpoint>#<leaseID>
#     - ttl_epoch (Number): TTL for automatic cleanup
#     - service_name (String): service that owns the lease
#     - created_ms (Number): creation timestamp
#
# Usage:
#   ./scripts/setup-conn-lease-table.sh [table-name] [region]
#
# Examples:
#   ./scripts/setup-conn-lease-table.sh                                    # Uses defaults
#   ./scripts/setup-conn-lease-table.sh my-conn-lease-table eu-west-1

set -euo pipefail

TABLE_NAME="${1:-temporal-dsql-conn-lease}"
REGION="${2:-${AWS_REGION:-eu-west-1}}"

echo "Creating DynamoDB table for connection lease tracking..."
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
#     Counter items: "dsqllease_counter#<endpoint>"
#     Lease items: "dsqllease#<endpoint>#<leaseID>"
#   ttl_epoch (Number) - TTL attribute for automatic lease cleanup
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

# Enable TTL on ttl_epoch attribute for automatic lease cleanup
# Lease items have TTL (3 minutes) - if a service crashes, its leases are
# automatically cleaned up by DynamoDB
echo "Enabling TTL on ttl_epoch attribute..."
aws dynamodb update-time-to-live \
    --table-name "$TABLE_NAME" \
    --time-to-live-specification "Enabled=true,AttributeName=ttl_epoch" \
    --region "$REGION" \
    --output text

echo ""
echo "✅ DynamoDB table '$TABLE_NAME' created successfully"
echo ""
echo "To enable distributed connection leasing, add to your .env:"
echo "  DSQL_DISTRIBUTED_CONN_LEASE_ENABLED=true"
echo "  DSQL_DISTRIBUTED_CONN_LEASE_TABLE=$TABLE_NAME"
echo "  DSQL_DISTRIBUTED_CONN_LIMIT=10000"
echo ""
echo "IAM permissions required for Temporal services:"
echo "  dynamodb:GetItem, dynamodb:PutItem, dynamodb:UpdateItem, dynamodb:DeleteItem"
echo "  dynamodb:TransactWriteItems"
echo "  on arn:aws:dynamodb:$REGION:*:table/$TABLE_NAME"
