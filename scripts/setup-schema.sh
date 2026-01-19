#!/bin/bash
set -euo pipefail

# Setup or update DSQL schema using temporal-dsql-tool
# This script uses the dedicated DSQL schema tool for simplified setup

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

# Parse command line arguments
ACTION="setup"
TARGET_VERSION=""
OVERWRITE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        update|--update|-u)
            ACTION="update"
            shift
            ;;
        setup|--setup|-s)
            ACTION="setup"
            shift
            ;;
        --version|-v)
            TARGET_VERSION="$2"
            shift 2
            ;;
        --overwrite)
            OVERWRITE="--overwrite"
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [setup|update] [options]"
            echo ""
            echo "Commands:"
            echo "  setup   Setup initial schema (default)"
            echo "  update  Update schema to target version"
            echo ""
            echo "Options:"
            echo "  --version, -v VERSION  Target version (default: 1.1 for setup, latest for update)"
            echo "  --overwrite            Drop existing tables before setup (setup only)"
            echo "  --help, -h             Show this help"
            echo ""
            echo "Examples:"
            echo "  $0                     # Setup schema v1.1"
            echo "  $0 setup               # Setup schema v1.1"
            echo "  $0 setup --overwrite   # Drop and recreate schema"
            echo "  $0 update              # Update to latest version"
            echo "  $0 update -v 1.1       # Update to specific version"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

echo "=== DSQL Schema $ACTION ==="
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
    echo "  cd ../temporal-dsql && go build -o temporal-dsql-tool ./cmd/tools/temporal-dsql-tool"
    exit 1
fi

echo "Configuration:"
echo "  DSQL Endpoint: $TEMPORAL_SQL_HOST"
echo "  Database: ${TEMPORAL_SQL_DATABASE:-postgres}"
echo "  User: ${TEMPORAL_SQL_USER:-admin}"
echo "  AWS Region: $AWS_REGION"
echo "  Action: $ACTION"
echo ""

# Schema name (updated from dsql/v12/temporal to dsql/temporal)
SCHEMA_NAME="dsql/temporal"

if [ "$ACTION" = "setup" ]; then
    # Setup schema
    VERSION="${TARGET_VERSION:-1.1}"
    echo "=== Setting up DSQL Schema ==="
    echo "Using embedded schema: $SCHEMA_NAME"
    echo "Version: $VERSION"
    echo ""

    $TEMPORAL_DSQL_TOOL \
        --endpoint "$TEMPORAL_SQL_HOST" \
        --port "${TEMPORAL_SQL_PORT:-5432}" \
        --user "${TEMPORAL_SQL_USER:-admin}" \
        --database "${TEMPORAL_SQL_DATABASE:-postgres}" \
        --region "$AWS_REGION" \
        setup-schema \
        --schema-name "$SCHEMA_NAME" \
        --version "$VERSION" \
        $OVERWRITE

    echo ""
    echo "✅ Schema setup completed (version $VERSION)"

elif [ "$ACTION" = "update" ]; then
    # Update schema
    echo "=== Updating DSQL Schema ==="
    echo "Using embedded schema: $SCHEMA_NAME"
    
    VERSION_FLAG=""
    if [ -n "$TARGET_VERSION" ]; then
        VERSION_FLAG="--version $TARGET_VERSION"
        echo "Target version: $TARGET_VERSION"
    else
        echo "Target version: latest"
    fi
    echo ""

    $TEMPORAL_DSQL_TOOL \
        --endpoint "$TEMPORAL_SQL_HOST" \
        --port "${TEMPORAL_SQL_PORT:-5432}" \
        --user "${TEMPORAL_SQL_USER:-admin}" \
        --database "${TEMPORAL_SQL_DATABASE:-postgres}" \
        --region "$AWS_REGION" \
        update-schema \
        --schema-name "$SCHEMA_NAME" \
        $VERSION_FLAG

    echo ""
    echo "✅ Schema update completed"
fi

echo ""
echo "Key tables:"
echo "  - cluster_metadata_info"
echo "  - executions"
echo "  - current_executions"
echo "  - current_chasm_executions (v1.1+)"
echo "  - activity_info_maps"
echo "  - timer_info_maps"
echo "  - And more..."
echo ""

echo "🎉 DSQL schema $ACTION completed!"
echo ""
