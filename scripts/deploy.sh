#!/bin/bash
set -euo pipefail

# Deploy DSQL infrastructure and generate environment configuration
# This script provisions Aurora DSQL and prepares the environment for Temporal

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

# Configuration
PROJECT_NAME="${PROJECT_NAME:-temporal-dsql-$(date +%s)}"
REGION="${AWS_REGION:-eu-west-1}"

echo "=== Deploying DSQL Infrastructure ==="
echo "Project Name: $PROJECT_NAME"
echo "Region: $REGION"
echo "Configuration: DSQL (AWS) + Environment Setup"
echo ""

# Step 1: Initialize Terraform
echo "=== Step 1: Initializing Terraform ==="
cd terraform
terraform init
echo ""

# Step 2: Plan deployment
echo "=== Step 2: Planning DSQL Deployment ==="
terraform plan \
    -var "project_name=$PROJECT_NAME" \
    -var "region=$REGION" \
    -out=tfplan
echo ""

# Step 3: Apply deployment
echo "=== Step 3: Deploying DSQL Infrastructure ==="
echo "This will create:"
echo "  - Aurora DSQL cluster (public endpoint)"
echo "  - Environment configuration for Temporal"
echo ""
read -p "Continue with deployment? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Deployment cancelled."
    exit 0
fi

terraform apply tfplan
echo ""

# Step 4: Extract outputs
echo "=== Step 4: Extracting Configuration ==="
terraform output -json > "$PROJECT_ROOT/terraform-outputs.json"

# Extract key values
DSQL_ENDPOINT=$(terraform output -raw dsql_public_endpoint)
DSQL_CLUSTER_ID=$(terraform output -raw dsql_cluster_identifier)

echo "✅ DSQL deployment completed successfully!"
echo ""
echo "=== Connection Information ==="
echo "DSQL Public Endpoint: $DSQL_ENDPOINT"
echo "DSQL Cluster ID: $DSQL_CLUSTER_ID"
echo ""

# Step 5: Generate environment file
echo "=== Step 5: Generating Environment Configuration ==="
cd "$PROJECT_ROOT"
ENV_FILE=".env"

cat > "$ENV_FILE" << EOF
# Temporal DSQL + Elasticsearch Configuration
# Generated: $(date)

# DSQL Configuration (Public Endpoint + IAM Auth)
TEMPORAL_SQL_HOST=$DSQL_ENDPOINT
TEMPORAL_SQL_PORT=5432
TEMPORAL_SQL_USER=admin
TEMPORAL_SQL_DATABASE=postgres
TEMPORAL_SQL_PLUGIN=dsql
TEMPORAL_SQL_PLUGIN_NAME=dsql
TEMPORAL_SQL_TLS_ENABLED=true
TEMPORAL_SQL_IAM_AUTH=true

# DSQL Connection Pool Settings (optimized for serverless)
TEMPORAL_SQL_MAX_CONNS=20
TEMPORAL_SQL_MAX_IDLE_CONNS=5
TEMPORAL_SQL_CONNECTION_TIMEOUT=30s
TEMPORAL_SQL_MAX_CONN_LIFETIME=300s

# Elasticsearch Configuration (Local Docker Container)
TEMPORAL_ELASTICSEARCH_HOST=elasticsearch
TEMPORAL_ELASTICSEARCH_PORT=9200
TEMPORAL_ELASTICSEARCH_SCHEME=http
TEMPORAL_ELASTICSEARCH_VERSION=v8
TEMPORAL_ELASTICSEARCH_INDEX=temporal_visibility_v1_dev

# AWS Configuration (for DSQL only)
AWS_REGION=$REGION
TEMPORAL_SQL_AWS_REGION=$REGION

# Temporal Configuration
TEMPORAL_LOG_LEVEL=info
TEMPORAL_HISTORY_SHARDS=4

# Docker Configuration
TEMPORAL_IMAGE=temporal-dsql-runtime:test
EOF

echo "Environment configuration saved to: $ENV_FILE"
echo ""

echo "Environment configuration saved to: $ENV_FILE"
echo ""

echo "=== Next Steps ==="
echo "1. Setup DSQL schema:"
echo "   ./scripts/setup-schema.sh"
echo ""
echo "2. Test the complete integration:"
echo "   ./scripts/test.sh"
echo ""
echo "3. Or start services manually:"
echo "   docker compose up -d"
echo ""
echo "4. Access Temporal UI:"
echo "   http://localhost:8080"
echo ""
echo "5. Monitor services:"
echo "   docker compose ps"
echo ""
echo "6. Cleanup when done:"
echo "   ./scripts/cleanup.sh"
echo ""

echo "🎉 DSQL infrastructure deployment completed!"
echo "⚠️  Remember to run ./scripts/setup-schema.sh to initialize the database schema."
echo "You now have Aurora DSQL provisioned. Next: setup schema and start services."