#!/bin/bash

# Recreate postgres database in DSQL using direct SQL commands
echo "🔄 Recreating postgres database in DSQL"
echo "========================================"
echo "DSQL doesn't support CREATE/DROP DATABASE commands via temporal-sql-tool"
echo "We'll use direct SQL commands to clear and recreate the database content"
echo ""

set -e

# Source environment
source .env.integration

echo "📡 DSQL Endpoint: $TEMPORAL_SQL_HOST"
echo "🗄️  Database: $TEMPORAL_SQL_DATABASE"
echo ""

# Step 1: Connect to DSQL and drop all Temporal tables
echo "1️⃣ Dropping all existing Temporal tables..."
echo "==========================================="

# Create a SQL script to drop all Temporal tables
cat > /tmp/drop_temporal_tables.sql << 'EOF'
-- Drop all Temporal tables in the correct order (respecting dependencies)
DROP TABLE IF EXISTS executions CASCADE;
DROP TABLE IF EXISTS current_executions CASCADE;
DROP TABLE IF EXISTS history_node CASCADE;
DROP TABLE IF EXISTS history_tree CASCADE;
DROP TABLE IF EXISTS workflow_executions CASCADE;
DROP TABLE IF EXISTS tasks CASCADE;
DROP TABLE IF EXISTS task_queues CASCADE;
DROP TABLE IF EXISTS transfer_tasks CASCADE;
DROP TABLE IF EXISTS timer_tasks CASCADE;
DROP TABLE IF EXISTS replication_tasks CASCADE;
DROP TABLE IF EXISTS visibility_tasks CASCADE;
DROP TABLE IF EXISTS activity_info_maps CASCADE;
DROP TABLE IF EXISTS timer_info_maps CASCADE;
DROP TABLE IF EXISTS child_execution_info_maps CASCADE;
DROP TABLE IF EXISTS request_cancel_info_maps CASCADE;
DROP TABLE IF EXISTS signal_info_maps CASCADE;
DROP TABLE IF EXISTS signals_requested_sets CASCADE;
DROP TABLE IF EXISTS buffered_events CASCADE;
DROP TABLE IF EXISTS domains CASCADE;
DROP TABLE IF EXISTS domain_metadata CASCADE;
DROP TABLE IF EXISTS cluster_metadata CASCADE;
DROP TABLE IF EXISTS cluster_metadata_info CASCADE;
DROP TABLE IF EXISTS cluster_membership CASCADE;
DROP TABLE IF EXISTS schema_version CASCADE;
DROP TABLE IF EXISTS schema_update_history CASCADE;
DROP TABLE IF EXISTS queue CASCADE;
DROP TABLE IF EXISTS queue_metadata CASCADE;

-- Drop any remaining sequences or other objects
DROP SEQUENCE IF EXISTS history_node_id_seq CASCADE;
DROP SEQUENCE IF EXISTS task_id_seq CASCADE;

SELECT 'All Temporal tables dropped successfully' as result;
EOF

# Execute the drop script using temporal-sql-tool
docker run --rm --network host \
    -e REGION=eu-west-1 \
    -e AWS_REGION=eu-west-1 \
    -e CLUSTER_ENDPOINT=$TEMPORAL_SQL_HOST \
    -e AWS_EC2_METADATA_DISABLED=true \
    -e AWS_PROFILE \
    -e AWS_ACCESS_KEY_ID \
    -e AWS_SECRET_ACCESS_KEY \
    -e AWS_SESSION_TOKEN \
    -v /tmp/drop_temporal_tables.sql:/tmp/drop_temporal_tables.sql:ro \
    -v $HOME/.aws:/root/.aws:ro \
    --user root \
    --entrypoint="" \
    temporal-dsql:latest \
    /usr/local/bin/temporal-sql-tool \
    --plugin dsql \
    --ep $TEMPORAL_SQL_HOST \
    --port 5432 \
    --user admin \
    --tls \
    --db $TEMPORAL_SQL_DATABASE \
    exec-sql \
    --file /tmp/drop_temporal_tables.sql

echo "✅ All Temporal tables dropped"

# Step 2: Verify database is clean
echo ""
echo "2️⃣ Verifying database is clean..."
echo "================================"

# Create verification script
cat > /tmp/verify_clean.sql << 'EOF'
-- List all remaining tables
SELECT table_name 
FROM information_schema.tables 
WHERE table_schema = 'public' 
  AND table_type = 'BASE TABLE'
ORDER BY table_name;

-- Count remaining tables
SELECT COUNT(*) as remaining_tables
FROM information_schema.tables 
WHERE table_schema = 'public' 
  AND table_type = 'BASE TABLE';
EOF

docker run --rm --network host \
    -e REGION=eu-west-1 \
    -e AWS_REGION=eu-west-1 \
    -e CLUSTER_ENDPOINT=$TEMPORAL_SQL_HOST \
    -e AWS_EC2_METADATA_DISABLED=true \
    -e AWS_PROFILE \
    -e AWS_ACCESS_KEY_ID \
    -e AWS_SECRET_ACCESS_KEY \
    -e AWS_SESSION_TOKEN \
    -v /tmp/verify_clean.sql:/tmp/verify_clean.sql:ro \
    -v $HOME/.aws:/root/.aws:ro \
    --user root \
    --entrypoint="" \
    temporal-dsql:latest \
    psql \
    "host=$TEMPORAL_SQL_HOST port=5432 dbname=$TEMPORAL_SQL_DATABASE user=admin sslmode=require" \
    -f /tmp/verify_clean.sql

echo "✅ Database verification complete"

# Cleanup temp files
rm -f /tmp/drop_temporal_tables.sql /tmp/verify_clean.sql

echo ""
echo "🎉 postgres database recreated (cleaned)!"
echo "========================================"
echo "✅ All Temporal tables and objects removed"
echo "✅ Database is now in a clean state"
echo "✅ Ready to run the schema reset script"
echo ""
echo "Next step: Run ./scripts/reset-dsql-schema-helm-approach.sh"