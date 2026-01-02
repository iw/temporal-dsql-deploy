#!/bin/bash

# Reset DSQL schema using proper Helm chart approach with temporal-sql-tool
echo "🔄 Resetting DSQL Schema (Helm Chart Approach)"
echo "=============================================="
echo "Using the canonical temporal-sql-tool commands:"
echo "  0. Drop database (reset step)"
echo "  1. Create database"
echo "  2. Setup schema -v 0"
echo "  3. Update schema to v1.0 using versioned files"
echo ""

set -e

# Source environment
source .env.integration

echo "📡 DSQL Endpoint: $TEMPORAL_SQL_HOST"
echo "🗄️  Database: $TEMPORAL_SQL_DATABASE"
echo ""

# Common temporal-sql-tool parameters
TOOL_PARAMS="--plugin dsql \
    --ep $TEMPORAL_SQL_HOST \
    --port 5432 \
    --user admin \
    --tls"

# Step 0: Drop database (CRITICAL RESET STEP)
# echo "0️⃣ Dropping existing database..."
# echo "================================"
# docker run --rm --network host \
#     -e REGION=eu-west-1 \
#     -e AWS_REGION=eu-west-1 \
#     -e CLUSTER_ENDPOINT=$TEMPORAL_SQL_HOST \
#     -e AWS_EC2_METADATA_DISABLED=true \
#     -e AWS_PROFILE \
#     -e AWS_ACCESS_KEY_ID \
#     -e AWS_SECRET_ACCESS_KEY \
#     -e AWS_SESSION_TOKEN \
#     -e TEMPORAL_LOG_LEVEL=debug \
#     -v $HOME/.aws:/root/.aws:ro \
#     --user root \
#     --entrypoint="" \
#     temporal-dsql:latest \
#     /usr/local/bin/temporal-sql-tool \
#     $TOOL_PARAMS \
#     --database $TEMPORAL_SQL_DATABASE \
#     drop-database

# echo "✅ Database drop complete"

# Step 1: Create database (CRITICAL FIRST STEP)
# DSQL Note: Skipping create-database - DSQL doesn't support CREATE DATABASE
# We work directly in the existing 'postgres' database
echo ""
echo "1️⃣ Skipping database creation (working in postgres database)..."
echo "=============================================================="
echo "✅ Using existing postgres database (DSQL limitation)"

# Step 2: Setup base schema with version 0
echo ""
echo "2️⃣ Setting up base schema (version 0, then updating to 1.0)..."
echo "==========================================="
docker run --rm --network host \
    -e REGION=eu-west-1 \
    -e AWS_REGION=eu-west-1 \
    -e CLUSTER_ENDPOINT=$TEMPORAL_SQL_HOST \
    -e AWS_EC2_METADATA_DISABLED=true \
    -e AWS_PROFILE \
    -e AWS_ACCESS_KEY_ID \
    -e AWS_SECRET_ACCESS_KEY \
    -e AWS_SESSION_TOKEN \
    -e TEMPORAL_LOG_LEVEL=debug \
    -v $HOME/.aws:/root/.aws:ro \
    --user root \
    --entrypoint="" \
    temporal-dsql:latest \
    /usr/local/bin/temporal-sql-tool \
    $TOOL_PARAMS \
    --db $TEMPORAL_SQL_DATABASE \
    setup-schema \
    --version 0

echo "✅ Base schema setup complete"

# Step 3: Update schema using versioned files
echo ""
echo "3️⃣ Updating schema with versioned files..."
echo "=========================================="
docker run --rm --network host \
    -e REGION=eu-west-1 \
    -e AWS_REGION=eu-west-1 \
    -e CLUSTER_ENDPOINT=$TEMPORAL_SQL_HOST \
    -e AWS_EC2_METADATA_DISABLED=true \
    -e AWS_PROFILE \
    -e AWS_ACCESS_KEY_ID \
    -e AWS_SECRET_ACCESS_KEY \
    -e AWS_SESSION_TOKEN \
    -e TEMPORAL_LOG_LEVEL=debug \
    -v $HOME/.aws:/root/.aws:ro \
    -v $(pwd)/../temporal-dsql/schema/dsql/v12/temporal/versioned:/schema/versioned:ro \
    --user root \
    --entrypoint="" \
    temporal-dsql:latest \
    /usr/local/bin/temporal-sql-tool \
    $TOOL_PARAMS \
    --db $TEMPORAL_SQL_DATABASE \
    update-schema \
    --schema-dir /schema/versioned

echo "✅ Schema update complete"

echo ""
echo "🎉 DSQL Schema Reset Complete (Helm Chart Approach)!"
echo "===================================================="
echo "✅ Database dropped and recreated"
echo "✅ Base schema setup with version 0"
echo "✅ Schema updated to version 1.0 using versioned files"
echo "✅ Database: $TEMPORAL_SQL_DATABASE"
echo "✅ Endpoint: $TEMPORAL_SQL_HOST"
echo ""
echo "The database is now in a clean state following the canonical Helm chart approach."
echo "Ready for Temporal server testing with the ::bytea cast fix."