#!/bin/bash
# Setup DynamoDB table for distributed DSQL connection lease tracking (Slot Blocks)
#
# This table coordinates global connection count limiting across all Temporal
# service instances to respect DSQL's 10,000 max connections limit.
#
# Uses a block-based allocation strategy to avoid hot partition issues:
# - Pre-allocates blocks of connection slots (default: 100 slots per block)
# - Each service acquires one or more blocks at startup
# - Once a block is owned, connections can be created without DynamoDB calls
# - TTL-based crash recovery ensures blocks are released if a service crashes
#
# Schema:
#   Slot block items: pk=connslots#<endpoint>#block-<i>
#     - owner_id (String): UUID of owning service (empty if unowned)
#     - ttl_epoch (Number): TTL for automatic cleanup / crash recovery
#     - slots (Number): Number of slots in this block
#     - service_name (String): Service that owns the block (for debugging)
#     - acquired_at_ms (Number): When the block was acquired
#     - renewed_at_ms (Number): When the TTL was last renewed
#     - released_at_ms (Number): When the block was released
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
#     Slot block items: "connslots#<endpoint>#block-<i>"
#   ttl_epoch (Number) - TTL attribute for automatic cleanup / crash recovery
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
# Slot blocks have TTL (default 3 minutes) - if a service crashes, its blocks are
# automatically released when TTL expires, allowing other services to acquire them
echo "Enabling TTL on ttl_epoch attribute..."
aws dynamodb update-time-to-live \
    --table-name "$TABLE_NAME" \
    --time-to-live-specification "Enabled=true,AttributeName=ttl_epoch" \
    --region "$REGION" \
    --output text

echo ""
echo "✅ DynamoDB table '$TABLE_NAME' created successfully"
echo ""
echo "To enable distributed connection leasing with slot blocks, add to your .env:"
echo "  DSQL_DISTRIBUTED_CONN_LEASE_ENABLED=true"
echo "  DSQL_DISTRIBUTED_CONN_LEASE_TABLE=$TABLE_NAME"
echo "  DSQL_SLOT_BLOCK_SIZE=100"
echo "  DSQL_SLOT_BLOCK_COUNT=100"
echo "  DSQL_SLOT_BLOCK_TTL=3m"
echo "  DSQL_SLOT_BLOCK_RENEW_INTERVAL=1m"
echo ""
echo "IAM permissions required for Temporal services:"
echo "  dynamodb:GetItem, dynamodb:PutItem, dynamodb:UpdateItem"
echo "  on arn:aws:dynamodb:$REGION:*:table/$TABLE_NAME"
