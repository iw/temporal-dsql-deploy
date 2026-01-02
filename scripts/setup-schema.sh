#!/bin/bash
set -euo pipefail

# Setup DSQL schema using temporal-dsql-tool
# This script uses the dedicated DSQL schema tool for simplified setup

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

echo "=== Setting up DSQL Schema ==="
echo ""

# Load environment variables
if [ -f ".env" ]; then
    source .env
    echo "✅ Loaded environment from .env"
    
    # Export AWS_REGION for temporal-dsql-tool
    export AWS_REGION="${AWS_REGION:-$TEMPORAL_SQL_AWS_REGION}"
    echo "✅ Using AWS region: $AWS_REGION"
else
    echo "❌ .env file not found"
    echo "Please run ./scripts/deploy.sh first or create .env manually"
    exit 1
fi

# Check if temporal-dsql-tool exists
TEMPORAL_DSQL_TOOL="../temporal-dsql/temporal-dsql-tool"
if [ ! -f "$TEMPORAL_DSQL_TOOL" ]; then
    echo "❌ temporal-dsql-tool not found at $TEMPORAL_DSQL_TOOL"
    echo "Please ensure the temporal-dsql repository is built:"
    echo "  cd ../temporal-dsql && go build ./cmd/tools/temporal-dsql-tool"
    exit 1
fi

echo "Configuration:"
echo "  DSQL Endpoint: $TEMPORAL_SQL_HOST"
echo "  Database: ${TEMPORAL_SQL_DATABASE:-postgres}"
echo "  User: ${TEMPORAL_SQL_USER:-admin}"
echo "  AWS Region: $AWS_REGION"
echo ""

# Setup schema using temporal-dsql-tool with embedded schema
# Note: We use --version 1.12 to create schema_version table required by Temporal server
echo "=== Setting up DSQL Schema ==="
echo "Using embedded schema: dsql/v12/temporal"
echo ""

$TEMPORAL_DSQL_TOOL \
    --endpoint "$TEMPORAL_SQL_HOST" \
    --port "${TEMPORAL_SQL_PORT:-5432}" \
    --user "${TEMPORAL_SQL_USER:-admin}" \
    --database "${TEMPORAL_SQL_DATABASE:-postgres}" \
    --region "$AWS_REGION" \
    setup-schema \
    --schema-name "dsql/v12/temporal" \
    --version 1.12

echo ""
echo "✅ Schema setup completed"
echo ""

echo "Key tables that should now exist:"
echo "  - cluster_metadata_info"
echo "  - executions"
echo "  - current_executions"
echo "  - activity_info_maps"
echo "  - timer_info_maps"
echo "  - child_execution_info_maps"
echo "  - request_cancel_info_maps"
echo "  - signal_info_maps"
echo "  - buffered_events"
echo "  - tasks"
echo "  - task_queues"
echo "  - And more..."
echo ""

echo "🎉 DSQL schema setup completed!"
echo ""
echo "Next steps:"
echo "1. Start Temporal services: docker compose up -d"
echo "2. Setup Elasticsearch index: ./scripts/setup-elasticsearch.sh"
echo "3. Test the setup: ./scripts/test.sh"
echo "4. Access Temporal UI: http://localhost:8080"
echo ""
