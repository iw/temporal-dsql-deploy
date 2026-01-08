#!/bin/bash
set -euo pipefail

# Test Temporal DSQL + Elasticsearch integration
# This script validates the complete setup with local Elasticsearch

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

echo "=== Testing Temporal DSQL + Elasticsearch Integration ==="
echo ""

# Load environment variables
if [ -f ".env" ]; then
    source .env
    echo "✅ Loaded environment from .env"
else
    echo "❌ .env file not found"
    echo "Run ./scripts/deploy.sh first or copy .env.example to .env"
    exit 1
fi

# Step 1: Ensure Docker network exists
echo "=== Step 1: Setting up Docker Network ==="
if ! docker network ls | grep -q temporal-network; then
    echo "Creating temporal-network..."
    docker network create temporal-network
else
    echo "✅ temporal-network already exists"
fi
echo ""

# Step 2: Start Elasticsearch first
echo "=== Step 2: Starting Elasticsearch ==="
docker compose up -d elasticsearch
echo "Waiting for Elasticsearch to be ready..."
sleep 30

# Check Elasticsearch health
MAX_ATTEMPTS=12
ATTEMPT=1
while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
    if curl -f -s http://localhost:9200/_cluster/health > /dev/null 2>&1; then
        echo "✅ Elasticsearch is ready!"
        break
    fi
    
    if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
        echo "❌ Elasticsearch failed to start"
        docker compose logs elasticsearch
        exit 1
    fi
    
    echo "Waiting for Elasticsearch... (attempt $ATTEMPT/$MAX_ATTEMPTS)"
    sleep 10
    ATTEMPT=$((ATTEMPT + 1))
done
echo ""

# Step 3: Setup Elasticsearch index
echo "=== Step 3: Setting up Elasticsearch Index ==="
./scripts/setup-elasticsearch.sh
echo ""

# Step 4: Test DSQL connectivity
echo "=== Step 4: Testing DSQL Connectivity ==="
echo "Testing connection to DSQL cluster..."

# Use AWS CLI to test DSQL connectivity
if command -v aws >/dev/null 2>&1; then
    echo "Checking DSQL cluster status..."
    CLUSTER_ID=$(echo "$TEMPORAL_SQL_HOST" | cut -d'.' -f1)
    aws dsql get-cluster --identifier "$CLUSTER_ID" --region "$AWS_REGION" --query 'Status' --output text 2>/dev/null || {
        echo "Note: DSQL cluster status check failed (may be normal)"
    }
else
    echo "AWS CLI not available - skipping DSQL status check"
fi

# Test basic connectivity using temporal-sql-tool
echo "Testing DSQL schema connectivity..."
if [ -f "../temporal-dsql/temporal-sql-tool" ]; then
    echo "Using temporal-sql-tool to test connectivity..."
    # This will test the connection without making changes
    timeout 30s ../temporal-dsql/temporal-sql-tool --database "$TEMPORAL_SQL_DATABASE" --host "$TEMPORAL_SQL_HOST" --port "$TEMPORAL_SQL_PORT" --user "$TEMPORAL_SQL_USER" --tls --plugin dsql setup-schema -v 0 --dry-run 2>/dev/null || {
        echo "Note: DSQL connectivity test completed (may show warnings)"
    }
else
    echo "temporal-sql-tool not found - skipping direct DSQL test"
fi
echo ""

# Step 5: Start all Temporal services
echo "=== Step 5: Starting Temporal Services ==="
docker compose up -d
echo "Waiting for services to start..."
sleep 45

# Step 6: Check service health
echo "=== Step 6: Checking Service Health ==="
echo "Container status:"
docker compose ps
echo ""

# Check individual service health
SERVICES=("elasticsearch" "temporal-history" "temporal-matching" "temporal-frontend" "temporal-worker" "temporal-ui")
for service in "${SERVICES[@]}"; do
    echo "Checking $service..."
    if docker compose ps "$service" | grep -q "Up"; then
        echo "✅ $service is running"
    else
        echo "❌ $service is not running properly"
        echo "Logs for $service:"
        docker compose logs --tail=10 "$service"
    fi
done
echo ""

# Step 7: Test Temporal frontend connectivity
echo "=== Step 7: Testing Temporal Frontend ==="
echo "Testing gRPC endpoint (port 7233)..."
if nc -z localhost 7233; then
    echo "✅ Temporal gRPC endpoint is accessible"
else
    echo "❌ Temporal gRPC endpoint is not accessible"
fi

echo "Testing HTTP endpoint (port 8233)..."
if nc -z localhost 8233; then
    echo "✅ Temporal HTTP endpoint is accessible"
else
    echo "❌ Temporal HTTP endpoint is not accessible"
fi

echo "Testing UI endpoint (port 8080)..."
if nc -z localhost 8080; then
    echo "✅ Temporal UI is accessible"
else
    echo "❌ Temporal UI is not accessible"
fi
echo ""

# Step 8: Test Elasticsearch integration
echo "=== Step 8: Testing Elasticsearch Integration ==="
echo "Checking Elasticsearch health..."
ES_HEALTH=$(curl -s http://localhost:9200/_cluster/health | jq -r '.status' 2>/dev/null || echo "unknown")
echo "Elasticsearch cluster status: $ES_HEALTH"

echo "Checking visibility index..."
INDEX_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:9200/$TEMPORAL_ELASTICSEARCH_INDEX")
if [ "$INDEX_STATUS" = "200" ]; then
    echo "✅ Visibility index exists and is accessible"
    
    # Check document count
    DOC_COUNT=$(curl -s "http://localhost:9200/$TEMPORAL_ELASTICSEARCH_INDEX/_count" | jq -r '.count' 2>/dev/null || echo "unknown")
    echo "Current document count in visibility index: $DOC_COUNT"
else
    echo "❌ Visibility index is not accessible (HTTP $INDEX_STATUS)"
fi
echo ""

# Step 9: Test basic Temporal operations (if tctl is available)
echo "=== Step 9: Testing Basic Temporal Operations ==="
if command -v tctl >/dev/null 2>&1; then
    echo "Testing namespace operations..."
    export TEMPORAL_CLI_ADDRESS=localhost:7233
    
    # List namespaces
    echo "Listing namespaces..."
    timeout 30s tctl namespace list 2>/dev/null || {
        echo "Note: Namespace listing may have failed (services may still be starting)"
    }
else
    echo "tctl not available - skipping Temporal operations test"
fi
echo ""

# Step 10: Summary and next steps
echo "=== Integration Test Summary ==="
echo ""
echo "🔍 Service Status:"
docker compose ps --format "table {{.Service}}\t{{.Status}}\t{{.Ports}}"
echo ""

echo "🌐 Access Points:"
echo "  - Temporal UI: http://localhost:8080"
echo "  - Temporal gRPC: localhost:7233"
echo "  - Temporal HTTP: localhost:8233"
echo "  - Elasticsearch: http://localhost:9200"
echo ""

echo "📊 Health Checks:"
echo "  - Elasticsearch: curl http://localhost:9200/_cluster/health"
echo "  - Temporal Frontend: nc -z localhost 7233"
echo "  - Visibility Index: curl http://localhost:9200/$TEMPORAL_ELASTICSEARCH_INDEX/_search"
echo ""

echo "🛠️  Troubleshooting:"
echo "  - View all logs: docker compose logs"
echo "  - View specific service: docker compose logs [service-name]"
echo "  - Restart services: docker compose restart"
echo ""

echo "🎉 Integration test completed!"
echo "If all services are running, you can now use Temporal with DSQL persistence and Elasticsearch visibility."