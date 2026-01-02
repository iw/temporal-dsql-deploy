#!/bin/bash
set -euo pipefail

echo "🔧 Testing Multi-Service Temporal DSQL Setup"
echo "============================================="

# Check if required files exist
if [[ ! -f "docker-compose.services.yml" ]]; then
    echo "❌ docker-compose.services.yml not found"
    exit 1
fi

if [[ ! -f ".env.integration" ]]; then
    echo "❌ .env.integration not found"
    exit 1
fi

if [[ ! -f "secrets/opensearch-password" ]]; then
    echo "❌ secrets/opensearch-password not found"
    exit 1
fi

echo "✅ Required files found"

# Rebuild the Docker image to include the new template
echo "🔨 Rebuilding Docker image with multi-service template..."
docker build -t temporal-dsql-runtime:test .

echo "🧹 Cleaning up any existing containers..."
docker compose -f docker-compose.services.yml down --remove-orphans || true

echo "🚀 Starting multi-service setup..."
docker compose -f docker-compose.services.yml up -d

echo "⏳ Waiting for services to start..."
sleep 10

echo "📊 Checking service status..."
docker compose -f docker-compose.services.yml ps

echo "🔍 Checking logs for errors..."
echo "--- History Service ---"
docker logs temporal-dsql-history --tail 20

echo "--- Matching Service ---"
docker logs temporal-dsql-matching --tail 20

echo "--- Frontend Service ---"
docker logs temporal-dsql-frontend --tail 20

echo "--- Worker Service ---"
docker logs temporal-dsql-worker --tail 20

echo "🏥 Checking frontend health..."
timeout 60 bash -c 'until curl -f http://localhost:8233/health; do echo "Waiting for frontend..."; sleep 5; done' || echo "❌ Frontend health check failed"

echo "🎯 Testing API connectivity..."
timeout 30 bash -c 'until docker exec temporal-dsql-frontend temporal operator namespace list; do echo "Waiting for API..."; sleep 5; done' || echo "❌ API test failed"

echo "✅ Multi-service setup test complete!"
echo "🌐 Access Temporal UI at: http://localhost:8080"
echo "🔧 Frontend gRPC: localhost:7233"
echo "🔧 Frontend HTTP: localhost:8233"