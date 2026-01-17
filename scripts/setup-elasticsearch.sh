#!/bin/bash
set -euo pipefail

# Setup Elasticsearch for Temporal visibility store
# This script initializes the Elasticsearch index using temporal-elasticsearch-tool (preferred) or curl (fallback)

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

echo "=== Setting up Elasticsearch for Temporal Visibility ==="
echo ""

# Configuration - using same variable names as Temporal samples
ES_HOST="${TEMPORAL_ELASTICSEARCH_HOST:-localhost}"
ES_PORT="${TEMPORAL_ELASTICSEARCH_PORT:-9200}"
ES_SCHEME="${TEMPORAL_ELASTICSEARCH_SCHEME:-http}"
ES_VISIBILITY_INDEX="${TEMPORAL_ELASTICSEARCH_INDEX:-temporal_visibility_v1_dev}"
ES_VERSION="${TEMPORAL_ELASTICSEARCH_VERSION:-v7}"

echo "Elasticsearch Configuration:"
echo "  URL: $ES_SCHEME://$ES_HOST:$ES_PORT"
echo "  Index: $ES_VISIBILITY_INDEX"
echo "  Version: $ES_VERSION"
echo ""

# Check if we have temporal-elasticsearch-tool available
TEMPORAL_ES_TOOL=""
if [ -x "../temporal-dsql/temporal-elasticsearch-tool" ]; then
    TEMPORAL_ES_TOOL="../temporal-dsql/temporal-elasticsearch-tool"
elif command -v temporal-elasticsearch-tool >/dev/null 2>&1; then
    TEMPORAL_ES_TOOL="temporal-elasticsearch-tool"
fi

# Setup Elasticsearch index
if [ -n "$TEMPORAL_ES_TOOL" ]; then
    echo "=== Using temporal-elasticsearch-tool for Elasticsearch setup ==="
    echo ""
    
    # Wait for Elasticsearch to be fully ready
    echo "Waiting for Elasticsearch to be ready..."
    max_attempts=30
    attempt=0
    until curl -s -f "$ES_SCHEME://$ES_HOST:$ES_PORT/_cluster/health?wait_for_status=yellow&timeout=5s" >/dev/null 2>&1; do
        attempt=$((attempt + 1))
        if [ $attempt -ge $max_attempts ]; then
            echo "❌ Elasticsearch did not become ready after $max_attempts attempts"
            exit 1
        fi
        echo "  Waiting... (attempt $attempt/$max_attempts)"
        sleep 2
    done
    echo "✅ Elasticsearch is ready"
    echo ""
    
    # Step 1: Setup schema (creates templates and cluster settings) with retry
    echo "Step 1: Setting up Elasticsearch schema..."
    for i in 1 2 3; do
        if $TEMPORAL_ES_TOOL --ep "$ES_SCHEME://$ES_HOST:$ES_PORT" setup-schema 2>&1; then
            echo "✅ Schema setup completed"
            break
        else
            if [ $i -eq 3 ]; then
                echo "❌ Schema setup failed after 3 attempts"
                exit 1
            fi
            echo "  Retrying schema setup... (attempt $((i+1))/3)"
            sleep 2
        fi
    done
    echo ""
    
    # Step 2: Check if index exists and has correct mappings
    echo "Step 2: Checking visibility index..."
    INDEX_EXISTS=$(curl -s -o /dev/null -w "%{http_code}" "$ES_SCHEME://$ES_HOST:$ES_PORT/$ES_VISIBILITY_INDEX")
    
    if [ "$INDEX_EXISTS" = "200" ]; then
        # Check if CloseTime mapping exists and is correct type
        CLOSETIME_TYPE=$(curl -s "$ES_SCHEME://$ES_HOST:$ES_PORT/$ES_VISIBILITY_INDEX/_mapping" | grep -o '"CloseTime":{[^}]*"type":"[^"]*"' | grep -o '"type":"[^"]*"' | head -1 || echo "")
        
        if [ -z "$CLOSETIME_TYPE" ] || [[ "$CLOSETIME_TYPE" != *"date"* ]]; then
            echo "  Index exists but has incorrect mappings (missing CloseTime or wrong type)"
            echo "  Deleting and recreating index..."
            curl -s -X DELETE "$ES_SCHEME://$ES_HOST:$ES_PORT/$ES_VISIBILITY_INDEX" >/dev/null
            sleep 1
            $TEMPORAL_ES_TOOL --ep "$ES_SCHEME://$ES_HOST:$ES_PORT" create-index --index "$ES_VISIBILITY_INDEX"
            echo "✅ Index '$ES_VISIBILITY_INDEX' recreated with correct mappings"
        else
            echo "✅ Index '$ES_VISIBILITY_INDEX' already exists with correct mappings"
        fi
    else
        # Create new index
        $TEMPORAL_ES_TOOL --ep "$ES_SCHEME://$ES_HOST:$ES_PORT" create-index --index "$ES_VISIBILITY_INDEX"
        echo "✅ Index '$ES_VISIBILITY_INDEX' created successfully"
    fi
    echo ""
    
    # Step 3: Verify setup with ping
    echo "Step 3: Verifying Elasticsearch connectivity..."
    $TEMPORAL_ES_TOOL --ep "$ES_SCHEME://$ES_HOST:$ES_PORT" ping
    echo "✅ Elasticsearch connectivity verified"
    echo ""
    
else
    echo "=== Using curl for Elasticsearch setup ==="
    echo "WARNING: temporal-elasticsearch-tool not found, falling back to curl"
    echo "Note: For production use, please use temporal-elasticsearch-tool from Temporal v1.30+"
    echo ""
    
    # Step 1: Wait for Elasticsearch to be ready
    echo "Step 1: Waiting for Elasticsearch to be ready..."
    max_attempts=30
    attempt=0
    
    until curl -s -f "$ES_SCHEME://$ES_HOST:$ES_PORT/_cluster/health?wait_for_status=yellow&timeout=1s" >/dev/null; do
        attempt=$((attempt + 1))
        if [ $attempt -ge $max_attempts ]; then
            echo "❌ Elasticsearch did not become ready after $max_attempts attempts"
            echo "Last error from curl:"
            curl "$ES_SCHEME://$ES_HOST:$ES_PORT/_cluster/health?wait_for_status=yellow&timeout=1s" 2>&1 || true
            exit 1
        fi
        echo "Elasticsearch not ready yet, waiting... (attempt $attempt/$max_attempts)"
        sleep 2
    done
    echo "✅ Elasticsearch is ready"
    echo ""
    
    # Step 2: Create index template (simplified version)
    echo "Step 2: Creating index template..."
    curl -X PUT --fail "$ES_SCHEME://$ES_HOST:$ES_PORT/_template/temporal_visibility_v1_template" \
        -H 'Content-Type: application/json' \
        -d '{
            "index_patterns": ["temporal_visibility_v1*"],
            "settings": {
                "number_of_shards": 1,
                "number_of_replicas": 0,
                "index.mapping.total_fields.limit": 2000
            },
            "mappings": {
                "properties": {
                    "ExecutionTime": {
                        "type": "date",
                        "format": "strict_date_optional_time||epoch_millis"
                    },
                    "CloseTime": {
                        "type": "date",
                        "format": "strict_date_optional_time||epoch_millis"
                    },
                    "StartTime": {
                        "type": "date",
                        "format": "strict_date_optional_time||epoch_millis"
                    }
                }
            }
        }'
    echo "✅ Index template created"
    echo ""
    
    # Step 3: Create index if it doesn't exist
    echo "Step 3: Creating visibility index..."
    curl --head --fail "$ES_SCHEME://$ES_HOST:$ES_PORT/$ES_VISIBILITY_INDEX" 2>/dev/null || \
        curl -X PUT --fail "$ES_SCHEME://$ES_HOST:$ES_PORT/$ES_VISIBILITY_INDEX"
    echo "✅ Index '$ES_VISIBILITY_INDEX' created successfully"
    echo ""
fi

# Final verification steps (common to both approaches)
echo "=== Final Verification ==="

# Check cluster health
echo "Cluster health:"
curl -s "$ES_SCHEME://$ES_HOST:$ES_PORT/_cat/health?v" || {
    echo "❌ Failed to get cluster health"
    exit 1
}
echo ""

# Check index status
echo "Index status:"
curl -s "$ES_SCHEME://$ES_HOST:$ES_PORT/_cat/indices/$ES_VISIBILITY_INDEX?v" || {
    echo "❌ Failed to get index information"
    exit 1
}
echo ""

# Test basic search functionality
echo "Testing search functionality..."
SEARCH_RESULT=$(curl -s "$ES_SCHEME://$ES_HOST:$ES_PORT/$ES_VISIBILITY_INDEX/_search" -H "Content-Type: application/json" -d '{
    "query": {
        "match_all": {}
    },
    "size": 0
}')

if echo "$SEARCH_RESULT" | grep -q '"hits"'; then
    echo "✅ Search functionality is working"
    echo "Current document count: $(echo "$SEARCH_RESULT" | jq -r '.hits.total.value // .hits.total' 2>/dev/null || echo "unknown")"
else
    echo "❌ Search functionality test failed"
    echo "Response: $SEARCH_RESULT"
    exit 1
fi
echo ""

echo "🎉 Elasticsearch setup completed successfully!"
echo ""
echo "=== Next Steps ==="
echo "1. Check service health:"
echo "   docker compose ps"
echo ""
echo "2. Access Temporal UI:"
echo "   http://localhost:8080"
echo ""
echo "3. Monitor Elasticsearch:"
echo "   curl $ES_SCHEME://$ES_HOST:$ES_PORT/_cat/health?v"
echo ""